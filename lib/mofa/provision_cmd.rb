require 'net/ssh'
require 'net/sftp'

class ProvisionCmd < MofaCmd
  attr_accessor :hostlist
  attr_accessor :runlist_map
  attr_accessor :attributes_map

  def initialize(token, cookbook)
    super(token, cookbook)
  end

  def prepare
    cookbook.prepare
  end

  def execute
    cookbook.execute

    hostlist.retrieve
    runlist_map.generate
    attributes_map.generate

    puts "Runlist Map: #{runlist_map.mp.inspect}"
    puts "Attributes Map: #{attributes_map.mp.inspect}"
    puts "Hostlist before runlist filtering: #{hostlist.list.inspect}"

    hostlist.filter_by_runlist_map(runlist_map)

    puts "Hostlist after runlist filtering: #{hostlist.list.inspect}"

    exit_code = run_chef_solo_on_hosts

    exit_code
  end

  def cleanup
    cookbook.cleanup
  end

  # FIXME
  # This Code is Copy'n'Pasted from the old mofa tooling. Only to make the MVP work in time!!
  # This needs to be refactored ASAP.

  def prepare_host(hostname, host_index, solo_dir)
    prerequesits_met = false
    puts
    puts "----------------------------------------------------------------------"
    puts "Chef-Solo on Host #{hostname} (#{host_index}/#{hostlist.list.length.to_s})"
    puts "----------------------------------------------------------------------"

    puts "Pinging host #{hostname}..."
    exit_status = system("ping -q -c 1 #{hostname} >/dev/null 2>&1")
    unless exit_status then
      puts "  --> Host #{hostname} is unavailable!"
      chef_solo_runs[hostname].store('status', 'UNAVAIL')
      chef_solo_runs[hostname].store('status_msg', "Host #{hostname} unreachable.")
    else
      puts "  --> Host #{hostname} is available."
      prerequesits_met = true
      Net::SSH.start(hostname, Mofa::Config.config['ssh_user'], :keys => [Mofa::Config.config['ssh_keyfile']], :port => Mofa::Config.config['ssh_port'], :verbose => :error) do |ssh|
        puts "Remotely creating solo_dir \"#{solo_dir}\" on host #{hostname}"
        # remotely create the temp folder
        out = ssh_exec!(ssh, "[ -d #{solo_dir} ] || mkdir #{solo_dir}")
        puts "ERROR (#{out[0]}): #{out[2]}" if out[0] != 0

        # remotely create a data_bags folder structure on the target host
        if cookbook.instance_of?(SourceCookbook) and File.directory?("#{cookbook.source_dir}/data_bags")
          Dir.entries("#{cookbook.source_dir}/data_bags").select { |f| !f.match(/^\.\.?$/) }.each do |data_bag|
            puts "Remotely creating data_bags dir \"#{solo_dir}/data_bags/#{data_bag}\""
            out = ssh_exec!(ssh, "[ -d #{solo_dir}/data_bags/#{data_bag} ] || mkdir -p #{solo_dir}/data_bags/#{data_bag}")
            puts "ERROR (#{out[0]}): #{out[2]}" if out[0] != 0
          end
        end
      end
    end
    prerequesits_met
  end

  def create_solo_rb(sftp, hostname, solo_dir)
    puts "Remotely creating \"#{solo_dir}/solo.rb\""
    sftp.file.open("#{solo_dir}/solo.rb", "w") do |file|
      if cookbook.instance_of?(SourceCookbook)
        solo_rb = <<-"EOF"
    cookbook_path [ "#{solo_dir}/cookbooks" ]
        EOF
      else
        solo_rb = <<-"EOF"
    recipe_url "#{solo_dir}/#{cookbook.pkg_name}"
        EOF
      end
      solo_rb += <<-"EOF"
    data_bag_path "#{solo_dir}/data_bags"
    log_level :info
    log_location "#{solo_dir}/log"
    verify_api_cert true
      EOF

      file.write(solo_rb)
    end
  end

  def create_node_json(sftp, hostname, solo_dir, attributes_map)
    puts "Remotely creating \"#{solo_dir}/node.json\""
    node_json = {}
    node_json.store('run_list', runlist_map.mp[hostname])
    attributes_map.mp[hostname].each do |key, value|
      node_json.store(key, value)
    end

    sftp.file.open("#{solo_dir}/node.json", "w") do |file|
      file.write(JSON.pretty_generate(node_json))
    end
  end

  def create_data_bags(sftp, hostname, solo_dir)
    if cookbook.instance_of?(SourceCookbook) and File.directory?("#{cookbook.source_dir}/data_bags")
      Dir.entries("#{cookbook.source_dir}/data_bags").select { |f| File.directory?(f) && !f.match(/^\.\.?$/) }.each do |data_bag|
        Dir.entries("#{cookbook.source_dir}/data_bags/#{data_bag}").select { |f| f.match(/\.json$/) }.each do |data_bag_item|
          puts "Uploading data_bag_item #{data_bag_item}... "
          sftp.upload!("#{cookbook.source_dir}/data_bags/#{data_bag}/#{data_bag_item}", "#{solo_dir}/data_bags/#{data_bag}/#{data_bag_item}")
          puts "OK."
        end
      end
    end
  end

  def run_chef_solo_on_hosts
    time = Time.new
    # Create a temp working dir on the target host
    solo_dir = '/var/tmp/' + time.strftime('%Y-%m-%d_%H%M%S')
    puts
    puts 'Chef-Solo Run started at ' + time.strftime('%Y-%m-%d %H:%M:%S')
    puts "Will use ssh_user #{Mofa::Config.config['ssh_user']}, ssh_port #{Mofa::Config.config['ssh_port']} and ssh_key_file #{Mofa::Config.config['ssh_keyfile']}"
    at_least_one_chef_solo_run_failed = false
    chef_solo_runs = {}
    host_index = 0
    hostlist.list.each do |hostname|
      host_index = host_index + 1
      next unless prepare_host(hostname, host_index, solo_dir)
      chef_solo_runs.store(hostname, {})

      Net::SFTP.start(hostname, Mofa::Config.config['ssh_user'], :keys => [Mofa::Config.config['ssh_keyfile']], :port =>  Mofa::Config.config['ssh_port'], :verbose => :error) do |sftp|

        # remotely creating solo.rb
        create_solo_rb(sftp, hostname, solo_dir)

        # remotely creating node.json
        create_node_json(sftp, hostname, solo_dir, attributes_map)

        # remotely create data_bag items
        create_data_bags(sftp, hostname, solo_dir)

        puts "Uploading Package #{cookbook.pkg_name}... "
        sftp.upload!("#{cookbook.pkg_dir}/#{cookbook.pkg_name}", "#{solo_dir}/#{cookbook.pkg_name}")
        puts "OK."

        # Do it -> Execute the chef-solo run!
        Net::SSH.start(hostname, Mofa::Config::config['ssh_user'], :keys => [Mofa::Config::config['ssh_keyfile']], :port =>  Mofa::Config.config['ssh_port'], :verbose => :error) do |ssh|

          if cookbook.instance_of?(SourceCookbook)
            puts "Remotely unpacking Snapshot Package #{cookbook.pkg_name}... "
            out = ssh_exec!(ssh, "cd #{solo_dir}; tar xvfz #{cookbook.pkg_name}")
            if out[0] != 0
              puts "ERROR (#{out[0]}): #{out[2]}"
              puts out[1]
            else
              puts "OK."
            end
          end

          puts "Remotely running chef-solo -c #{solo_dir}/solo.rb -j #{solo_dir}/node.json"
          out = ssh_exec!(ssh, "sudo chef-solo -c #{solo_dir}/solo.rb -j #{solo_dir}/node.json")
          if out[0] != 0
            puts "ERROR (#{out[0]}): #{out[2]}"
            out = ssh_exec!(ssh, "sudo cat #{solo_dir}/log")
            puts "ERROR (#{out[0]}): #{out[2]}" if out[0] != 0
            puts out[1]
            chef_solo_runs[hostname].store('status', 'FAIL')
            chef_solo_runs[hostname].store('status_msg', out[1])
          else
            unless Mofa::CLI::option_debug
              out = ssh_exec!(ssh, "sudo grep 'Chef Run' #{solo_dir}/log")
              puts "ERROR (#{out[0]}): #{out[2]}" if out[0] != 0
              puts "Done."
            else
              out = ssh_exec!(ssh, "sudo cat #{solo_dir}/log")
              puts "ERROR (#{out[0]}): #{out[2]}" if out[0] != 0
              puts out[1]
            end
            chef_solo_runs[hostname].store('status', 'SUCCESS')
            chef_solo_runs[hostname].store('status_msg', '')
          end
          out = ssh_exec!(ssh, "sudo chown -R #{Mofa::Config.config['ssh_user']}.#{Mofa::Config.config['ssh_user']} #{solo_dir}")
          puts "ERROR (#{out[0]}): #{out[2]}" if out[0] != 0
          out = ssh_exec!(ssh, "sudo mkdir -p /var/lib/mofa && ln -s #{solo_dir} /var/lib/mofa/last_run && echo #{cookbook.pkg_name} > /var/lib/mofa/last_cookbook && echo #{chef_solo_runs[hostname]['status']} > /var/lib/mofa/last_status")
          puts "ERROR (#{out[0]}): #{out[2]}" if out[0] != 0
        end
      end
      at_least_one_chef_solo_run_failed = true if chef_solo_runs[hostname]['status'] == 'FAIL'
    end

    # ------- print out report
    puts
    puts "----------------------------------------------------------------------"
    puts "Chef-Solo Run REPORT"
    puts "----------------------------------------------------------------------"
    puts "Chef-Solo has been run on #{chef_solo_runs.keys.length.to_s} hosts."

    chef_solo_runs.each do |hostname, content|
      status_msg = ''
      status_msg = "(#{content['status_msg']})" if content['status'] == 'FAIL'
      puts "#{content['status']}: #{hostname} #{status_msg}"
    end

    exit_code = 0
    if at_least_one_chef_solo_run_failed
      exit_code = 1
    end

    puts "Exiting with exit code #{exit_code}."

    if exit_code != 0
      raise Thor::Error, "Chef client exited with non zero exit code: #{exit_code}"
    end
    exit_code

  end

end
