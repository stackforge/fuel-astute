#    Copyright 2014 Mirantis, Inc.
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
  class StopOSTServices < PreNodeAction

    def process(deployment_info, context)
      old_env = deployment_info.first['openstack_version_prev']
      return if old_env.nil?

      Astute.logger.info "Stop all Openstack services hook start"

      target_file = '/tmp/stop_services.rb'
      source_file = 'stop_services.script'
      file_content = File.read File.join(File.dirname(__FILE__), source_file)
      node_uids = deployment_info.first['nodes'].collect { |n| n['uid'] }

      Astute.logger.info "Uploading file: #{target_file} to nodes uids: #{node_uids.join ', '}"

      MClient.new(context, "uploadfile", node_uids).upload(
        :path => target_file,
        :content => file_content,
        :user_owner => 'root',
        :group_owner => 'root',
        :permissions => '0700',
        :overwrite => true,
        :parents => true
      )

      Astute.logger.info "Running file: #{target_file} on node uids:  #{node_uids.join ', '}"

      response = run_shell_command(context, node_uids, "/usr/bin/ruby #{target_file} |tee /tmp/stop_services.log")

      if response[:data][:exit_code] != 0
        Astute.logger.warn "#{context.task_id}: Script returned error code #{response[:data][:exit_code]}"
      end

      Astute.logger.info "#{context.task_id}: Finished stop services pre-patching hook"
    end #process

  end #class
end #module
