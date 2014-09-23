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
  class PreNodePatching < PreNodeAction

    def process(deployment_info, context)
      return unless deployment_info.first['openstack_version_prev']

      nodes = deployment_info.map { |n| n['uid'] }
      cmd = 'ruby /etc/puppet/modules/fuel-patching-hooks/lib/pre-node.rb'
      desc = 'Pre node patching'

      Astute.logger.info "#{desc} " \
        "Executing command #{cmd} " \
        "On nodes #{nodes.inspect}"

      response = run_shell_command(context, nodes, cmd, 600)

      if response[:data][:exit_code] != 0
        Astute.logger.warn "#{context.task_id}: #{desc} failed, " \
                             "check the debugging output for details"
      end

      Astute.logger.info "#{context.task_id}: #{desc} finished"
    end #process

  end #class
end