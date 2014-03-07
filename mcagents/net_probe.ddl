metadata    :name        => "Network Probe Agent",
            :description => "Check network connectivity between nodes.",
            :author      => "Andrey Danin",
            :license     => "MIT",
            :version     => "0.1",
            :url         => "http://mirantis.com",
            :timeout     => 120

action "start_frame_listeners", :description => "Starts catching packets on interfaces" do
    display :always
end

action "send_probing_frames", :description => "Sends packets with VLAN tags" do
    display :always
end

action "get_probing_info", :description => "Get info about packets catched" do
    display :always
end

action "stop_frame_listeners", :description => "Stop catching packets, dump data to file" do
    display :always
end

action "echo", :description => "Silly echo" do
    display :always
end

action "dhcp_discover", :description => "Find dhcp server for provided interfaces" do
    display :always
end

action "check", :description => "Check action should be used for seamless message passing to python bindings" do
    display :always

    input :command,
          :description => "Any of the listen | send | get_info",
          :display_as  => "Command"

    input :check,
          :description => "Any of the available network checks",
          :display_as  => "Network check"

    input :config,
          :description => "Specifical info for each check",
          :display_as  => "Configuration for network check"
end
