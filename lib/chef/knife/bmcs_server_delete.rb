# Copyright (c) 2017 Oracle and/or its affiliates. All rights reserved.

require 'chef/knife'
require 'chef/knife/bmcs_helper'
require 'chef/knife/bmcs_common_options'

# max interval for polling the server state
MAX_INTERVAL_SECONDS = 3

class Chef
  class Knife
    # Server Delete Command: Delete a BMCS instance.
    class BmcsServerDelete < Knife
      banner 'knife bmcs server delete (options)'

      include BmcsHelper
      include BmcsCommonOptions

      deps do
        require 'oraclebmc'
        require 'chef/knife/bootstrap'
      end

      option :instance_id,
             long: '--instance-id INSTANCE',
             description: 'The OCID of the instance to be deleted. (required)'

      option :wait,
             long: '--wait SECONDS',
             description: 'Wait for the instance to be terminated. 0=infinite'

      option :purge,
             long: '--purge',
             description: 'Also remove node from Chef server. Chef node name defaults to the instance display name unless node-name is specified.'

      option :chef_node_name,
             short: '-N NAME',
             long: '--node-name NAME',
             description: 'The Chef node name being removed. If not specified, the instance display name will be used.'

      def run
        $stdout.sync = true
        validate_required_params(%i[instance_id], config)
        wait_for = validate_wait
        if config[:chef_node_name] && !config[:purge]
          error_and_exit('--node-name requires --purge argument')
        end

        response = check_can_access_instance(config[:instance_id])

        ui.msg "Instance name: #{response.data.display_name}"
        deletion_prompt = 'Delete server? (y/n)'
        chef_node = nil
        if config[:purge]
          deletion_prompt = 'Delete server and chef node? (y/n)'
          node_name = response.data.display_name
          node_name = config[:chef_node_name] if config[:chef_node_name]
          chef_node = get_chef_node(node_name)
          ui.msg "Chef node name: #{chef_node.name}"
        end
        confirm_deletion(deletion_prompt)

        terminate_instance(config[:instance_id])
        delete_chef_node(chef_node) if config[:purge]

        wait_for_instance_terminated(config[:instance_id], wait_for) if wait_for
      end

      def terminate_instance(instance_id)
        compute_client.terminate_instance(instance_id)

        ui.msg "Initiated delete of instance #{instance_id}"
      end

      def get_chef_node(node_name)
        node = Chef::Node.load(node_name)
        node
      end

      def delete_chef_node(node)
        node.destroy
        ui.msg "Deleted Chef node '#{node.name}'"
      end

      def wait_for_instance_terminated(instance_id, wait_for)
        print ui.color('Waiting for instance to terminate...', :magenta)
        begin
          begin
            compute_client.get_instance(instance_id).wait_until(:lifecycle_state,
                                                                OracleBMC::Core::Models::Instance::LIFECYCLE_STATE_TERMINATED,
                                                                get_wait_options(wait_for)) do
              show_progress
            end
          ensure
            end_progress_indicator
          end
        rescue OracleBMC::Waiter::Errors::MaximumWaitTimeExceededError
          error_and_exit 'Timeout exceeded while waiting for instance to terminate'
        rescue OracleBMC::Errors::ServiceError => service_error
          raise unless service_error.serviceCode == 'NotAuthorizedOrNotFound'
          # we'll soak this exception since the terminate may have completed before we started waiting for it.
          ui.warn 'Instance not authorized or not found'
        end
      end

      def validate_wait
        wait_for = nil
        if config[:wait]
          wait_for = Integer(config[:wait])
          error_and_exit 'Wait value must be 0 or greater' if wait_for < 0
        end
        wait_for
      end

      def get_wait_options(wait_for)
        opts = {
          max_interval_seconds: MAX_INTERVAL_SECONDS
        }
        opts[:max_wait_seconds] = wait_for if wait_for > 0
        opts
      end

      def confirm_deletion(prompt)
        if confirm(prompt)
          # we have user's confirmation, so avoid any further confirmation prompts from Chef
          config[:yes] = true
          return
        end
        error_and_exit 'Server delete canceled.'
      end

      def show_progress
        print ui.color('.', :magenta)
        $stdout.flush
      end

      def end_progress_indicator
        print ui.color("done\n", :magenta)
      end
    end
  end
end
