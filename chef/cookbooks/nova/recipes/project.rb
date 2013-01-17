#
# Cookbook Name:: nova
# Recipe:: setup
#
# Copyright 2010-2011, Opscode, Inc.
# Copyright 2011, Anso Labs
# Copyright 2011, Dell, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe "nova::database"
include_recipe "nova::config"

# ha_enabled activates Nova High Availability (HA) networking.
# The nova "network" and "api" recipes need to be included on the compute nodes and
# we must specify the --multi_host=T switch on "nova-manage network create". 
cmd = "nova-manage network create --fixed_range_v4=#{node[:nova][:network][:fixed_range]} --num_networks=#{node[:nova][:network][:num_networks]} --network_size=#{node[:nova][:network][:network_size]} --label nova_fixed" 
cmd << " --multi_host=T" if node[:nova][:network][:ha_enabled]
execute cmd do
  user node[:nova][:user] if node.platform != "suse"
  not_if "nova-manage network list | grep '#{node[:nova][:network][:fixed_range].split("/")[0]}'"
end

# Add private network one day.

base_ip = node[:nova][:network][:floating_range].split("/")[0]
grep_ip = base_ip[0..-2] + (base_ip[-1].chr.to_i+1).to_s

execute "nova-manage floating create --ip_range=#{node[:nova][:network][:floating_range]}" do
  user node[:nova][:user] if node.platform != "suse"
  not_if "nova-manage floating list | grep '#{grep_ip}'"
end

unless node[:nova][:network][:tenant_vlans]
  sql_engine = node[:nova][:db][:sql_engine]
  env_filter = " AND #{sql_engine}_config_environment:#{sql_engine}-config-#{node[:nova][:db][:sql_instance]}"
  db_server = search(:node, "roles:#{sql_engine}-server#{env_filter}")[0]
  db_server = node if db_server.name == node.name
  backend_name = Chef::Recipe::Database::Util.get_backend_name(db_server)

  execute "sql-fix-ranges-fixed" do
    case backend_name
      when "mysql"
        command "/usr/bin/mysql -u #{node[:nova][:db][:user]} -h #{db_server[:database][:api_bind_host]} -p#{node[:nova][:db][:password]} #{node[:nova][:db][:database]} < /etc/nova/nova-fixed-range.sql"
      when "postgresql"
        command "PGPASSWORD=#{node[:nova][:db][:password]} psql -h #{db_server[:database][:api_bind_host]} -U #{node[:nova][:db][:user]} #{node[:nova][:db][:database]} < /etc/nova/nova-fixed-range.sql"
    end
    action :nothing
  end

  fixed_net = node[:network][:networks]["nova_fixed"]
  rangeH = fixed_net["ranges"]["dhcp"]
  netmask = fixed_net["netmask"]
  subnet = fixed_net["subnet"]

  index = IPAddr.new(rangeH["start"]) & ~IPAddr.new(netmask)
  index = index.to_i
  stop_address = IPAddr.new(rangeH["end"]) & ~IPAddr.new(netmask)
  stop_address = IPAddr.new(subnet) | (stop_address.to_i + 1)
  address = IPAddr.new(subnet) | index

  network_list = []
  while address != stop_address
    network_list << address.to_s
    index = index + 1
    address = IPAddr.new(subnet) | index
  end
  network_list << address.to_s

  template "/etc/nova/nova-fixed-range.sql" do
    path "/etc/nova/nova-fixed-range.sql"
    source "fixed-range.sql.erb"
    owner "root"
    group "root"
    mode "0600"
    variables(
      :network => network_list
    )
    notifies :run, resources(:execute => "sql-fix-ranges-fixed"), :immediately
  end
end

# Setup administrator credentials file
env_filter = " AND keystone_config_environment:keystone-config-#{node[:nova][:keystone_instance]}"
keystones = search(:node, "recipes:keystone\\:\\:server#{env_filter}") || []
if keystones.length > 0
  keystone = keystones[0]
  keystone = node if keystone.name == node.name
else
  keystone = node
end

# For the public endpoint, we prefer the public name. If not set, then we use
# the IP address except for SSL, where we always prefer a hostname (for
# certificate validation)
if keystone[:crowbar][:public_name].nil? and keystone[:keystone][:api][:protocol] != "https"
  public_keystone_host = Chef::Recipe::Barclamp::Inventory.get_network_by_type(keystone, "public").address
else
  public_keystone_host = keystone[:crowbar][:public_name].nil? ? 'public.'+keystone[:fqdn] : keystone[:crowbar][:public_name]
end
keystone_protocol = keystone["keystone"]["api"]["protocol"]
keystone_token = keystone["keystone"]["admin"]["token"] rescue nil
admin_username = keystone["keystone"]["admin"]["username"] rescue nil
admin_password = keystone["keystone"]["admin"]["password"] rescue nil
default_tenant = keystone["keystone"]["default"]["tenant"] rescue nil
keystone_service_port = keystone["keystone"]["api"]["service_port"] rescue nil
Chef::Log.info("Keystone server found at #{public_keystone_host}")

apis = search(:node, "recipes:nova\\:\\:api#{env_filter}") || []
if apis.length > 0 and !node[:nova][:network][:ha_enabled]
  api = apis[0]
  api = node if api.name == node.name
else
  api = node
end
# For the public endpoint, we prefer the public name. If not set, then we use
# the IP address except for SSL, where we always prefer a hostname (for
# certificate validation)
if api[:crowbar][:public_name].nil? and api[:nova][:api][:protocol] != "https"
   public_api_host = Chef::Recipe::Barclamp::Inventory.get_network_by_type(api, "public").address
else
   public_api_host = api[:crowbar][:public_name].nil? ? 'public.'+api[:fqdn] : api[:crowbar][:public_name]
end
api_scheme = api[:nova][:api][:protocol]
Chef::Log.info("Admin API server found at #{public_api_host}")

# install python-glanceclient on controller, to be able to upload images
# from here
package "python-glanceclient" do
  action :upgrade
end

template "/root/.openrc" do
  source "openrc.erb"
  owner "root"
  group "root"
  mode 0600
  variables(
    :keystone_protocol => keystone_protocol,
    :keystone_host => public_keystone_host,
    :keystone_service_port => keystone_service_port,
    :admin_username => admin_username,
    :admin_password => admin_password,
    :default_tenant => default_tenant,
    :nova_api_protocol => api_scheme,
    :nova_api_host => public_api_host
  )
end

