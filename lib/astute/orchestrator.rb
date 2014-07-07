#    Copyright 2013 Mirantis, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

module Astute

  class Orchestrator
    def initialize(deploy_engine=nil, log_parsing=false)
      @deploy_engine = deploy_engine || Astute::DeploymentEngine::NailyFact
      @log_parsing = log_parsing
    end

    def node_type(reporter, task_id, nodes, timeout=nil)
      context = Context.new(task_id, reporter)
      uids = nodes.map {|n| n['uid']}
      systemtype = MClient.new(context, "systemtype", uids, check_result=false, timeout)
      systems = systemtype.get_type
      systems.map do |n|
        {
          'uid'       => n.results[:sender],
          'node_type' => n.results[:data][:node_type].chomp
        }
      end
    end

    def deploy(up_reporter, task_id, deployment_info)
      proxy_reporter = ProxyReporter::DeploymentProxyReporter.new(up_reporter, deployment_info)
      log_parser = @log_parsing ? LogParser::ParseDeployLogs.new : LogParser::NoParsing.new
      context = Context.new(task_id, proxy_reporter, log_parser)
      deploy_engine_instance = @deploy_engine.new(context)
      Astute.logger.info "Using #{deploy_engine_instance.class} for deployment."

      deploy_engine_instance.deploy(deployment_info)

      # Post deploy hooks
      PostDeployActions.new(deployment_info, context).process

      context.status
    end

    def provision(reporter, task_id engine_attrs, nodes)
      raise "Nodes to provision are not provided!" if nodes.empty?
      provision_method = engine_attrs['provision_method'] || 'cobbler'

      cobbler = CobblerManager.new(engine_attrs, reporter)
      begin
        remove_nodes(reporter, task_id="", engine_attrs, nodes, reboot=false)
        cobbler.add_nodes(nodes)

        # if provision_method is 'image', we do not need to immediately
        # reboot nodes. instead, we need to run image based provisioning
        # process and then reboot nodes
        if provision_method == 'image'
          failed_uids_provis = ImageProvision.provision(Context.new(task_id, reporter), nodes)
          if failed_uids_provis.empty?
            reporter.report({
              'status' => 'provisioning',
              'progress' => 80,
              'msg' => 'Nodes have beed successfully provisioned. Next step is reboot.'
            })
            # disabling pxe boot
            cobbler.netboot_nodes(nodes, false)
          else
            err_msg = 'At least one of nodes have failed during provisioning'
            Astute.logger.error("#{task_id}: #{err_msg}")
            reporter.report({
              'status' => 'error',
              'progress' => 100,
              'msg' => err_msg,
              'error_type' => 'provision'
            })
            raise FailedImageProvisionError.new(err_msg)
          end
        end
        reboot_events = cobbler.reboot_nodes(nodes)
        failed_nodes = cobbler.check_reboot_nodes(reboot_events)
      rescue RuntimeError => e
        Astute.logger.error("Error occured while provisioning: #{e.inspect}")
        reporter.report({
            'status' => 'error',
            'error' => 'Cobbler error',
            'progress' => 100})
        raise e
      end

      if failed_nodes.present?
        err_msg = "Nodes failed to reboot: #{failed_nodes.inspect}"
        Astute.logger.error(err_msg)
        reporter.report({'status' => 'error',
                         'error' => err_msg,
                         'progress' => 100})
        raise FailedToRebootNodesError.new(err_msg)
      end

      watch_provision_progress(reporter, task_id, nodes)
    end

    def watch_provision_progress(reporter, task_id, nodes)
      raise "Nodes to provision are not provided!" if nodes.empty?

      provision_log_parser = @log_parsing ? LogParser::ParseProvisionLogs.new : LogParser::NoParsing.new
      proxy_reporter = ProxyReporter::DeploymentProxyReporter.new(reporter)

      prepare_logs_for_parsing(provision_log_parser, nodes)

      nodes_not_booted = nodes.map{ |n| n['uid'] }
      result_msg = {'nodes' => []}
      begin
        Timeout.timeout(Astute.config.PROVISIONING_TIMEOUT) do  # Timeout for booting target OS
          catch :done do
            loop do
              sleep_not_greater_than(5) do
                nodes_types = node_type(proxy_reporter, task_id, nodes, 2)
                target_uids, nodes_not_booted = analize_node_types(nodes_types, nodes_not_booted)

                if nodes.length == target_uids.length
                  Astute.logger.info "All nodes #{target_uids.join(',')} are provisioned."
                  throw :done
                end

                Astute.logger.debug('Nodes list length is not equal to target ' +
                  "nodes list length: #{nodes.length} != #{target_uids.length}")
                report_about_progress(proxy_reporter, provision_log_parser, target_uids, nodes)
              end
            end
          end
          # We are here if jumped by throw from while cycle
        end
      rescue Timeout::Error
        Astute.logger.error("Timeout of provisioning is exceeded. Nodes not booted: #{nodes_not_booted}")
        nodes_progress = nodes_not_booted.map do |n|
          {
            'uid' => n,
            'status' => 'error',
            'error_msg' => "Timeout of provisioning is exceeded",
            'progress' => 100,
            'error_type' => 'provision'
          }
        end

        result_msg.merge!({
            'status' => 'error',
            'error' => 'Timeout of provisioning is exceeded',
            'progress' => 100})

        result_msg['nodes'] += nodes_progress
      end

      node_uids = nodes.map { |n| n['uid'] }
      (node_uids - nodes_not_booted).each do |uid|
        result_msg['nodes'] << {'uid' => uid, 'progress' => 100, 'status' => 'provisioned'}
      end

      # If there was no errors, then set status to ready
      result_msg.reverse_merge!({'status' => 'ready', 'progress' => 100})

      proxy_reporter.report(result_msg)

      result_msg
    end

    def remove_nodes(reporter, task_id, engine_attrs, nodes, reboot=true)
      cobbler = CobblerManager.new(engine_attrs, reporter)
      cobbler.remove_nodes(nodes)
      ctxt = Context.new(task_id, reporter)
      result = NodesRemover.new(ctxt, nodes, reboot).remove
      Rsyslogd.send_sighup(ctxt, engine_attrs["master_ip"])

      result
    end

    def stop_puppet_deploy(reporter, task_id, nodes)
      nodes_uids = nodes.map { |n| n['uid'] }.uniq
      puppetd = MClient.new(Context.new(task_id, reporter), "puppetd", nodes_uids, check_result=false)
      puppetd.stop_and_disable
    end

    def stop_provision(reporter, task_id, engine_attrs, nodes)
      Ssh.execute(Context.new(task_id, reporter), nodes, SshEraseNodes.command)
      CobblerManager.new(engine_attrs, reporter).remove_nodes(nodes)
      Ssh.execute(Context.new(task_id, reporter),
                  nodes,
                  SshHardReboot.command,
                  timeout=5,
                  retries=1)
    end

    def dump_environment(reporter, task_id, settings)
      Dump.dump_environment(Context.new(task_id, reporter), settings)
    end

    def verify_networks(reporter, task_id, nodes)
      Network.check_network(Context.new(task_id, reporter), nodes)
    end

    def check_dhcp(reporter, task_id, nodes)
      Network.check_dhcp(Context.new(task_id, reporter), nodes)
    end

    def multicast_verification(reporter, task_id, nodes)
      Network.multicast_verification(Context.new(task_id, reporter), nodes)
    end

    private

    def report_result(result, reporter)
      default_result = {'status' => 'ready', 'progress' => 100}

      result = {} unless result.instance_of?(Hash)
      status = default_result.merge(result)
      reporter.report(status)
    end

    def prepare_logs_for_parsing(provision_log_parser, nodes)
      sleep_not_greater_than(10) do # Wait while nodes going to reboot
        Astute.logger.info "Starting OS provisioning for nodes: #{nodes.map{ |n| n['uid'] }.join(',')}"
        begin
          provision_log_parser.prepare(nodes)
        rescue => e
          Astute.logger.warn "Some error occurred when prepare LogParser: #{e.message}, trace: #{e.format_backtrace}"
        end
      end
    end

    def analize_node_types(types, nodes_not_booted)
      types.each { |t| Astute.logger.debug("Got node types: uid=#{t['uid']} type=#{t['node_type']}") }
      target_uids = types.reject{ |n| n['node_type'] != 'target' }.map{ |n| n['uid'] }
      Astute.logger.debug("Not target nodes will be rejected")

      nodes_not_booted -= types.map { |n| n['uid'] }
      Astute.logger.debug "Not provisioned: #{nodes_not_booted.join(',')}, got target OSes: #{target_uids.join(',')}"
      return target_uids, nodes_not_booted
    end

    def sleep_not_greater_than(sleep_time, &block)
      time = Time.now.to_f
      block.call
      time = time + sleep_time - Time.now.to_f
      sleep(time) if time > 0
    end

    def report_about_progress(reporter, provision_log_parser, target_uids, nodes)
      begin
        nodes_progress = provision_log_parser.progress_calculate(nodes.map{ |n| n['uid'] }, nodes)
        nodes_progress.each do |n|
          if target_uids.include?(n['uid'])
            n['progress'] = 100
            n['status']   = 'provisioned'
          else
            n['status']   = 'provisioning'
          end
        end
        reporter.report({'nodes' => nodes_progress})
      rescue => e
        Astute.logger.warn "Some error occurred when parse logs for nodes progress: #{e.message}, trace: #{e.format_backtrace}"
      end
    end

  end
end
