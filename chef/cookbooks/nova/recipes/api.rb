#
# Cookbook Name:: nova
# Recipe:: api
#
# Copyright 2010, Opscode, Inc.
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

include_recipe "nova::config"

# https is only used on the nova-multi-controller
if node[:nova][:api][:protocol] == "https" and node["roles"].include?("nova-multi-controller")
  include_recipe "apache2"
  include_recipe "apache2::mod_ssl"
  include_recipe "apache2::mod_wsgi"
end

package "python-keystone" do
  action :upgrade
end
package "python-novaclient" do
  action :upgrade
end

# https is only used on the nova-multi-controller
if node[:nova][:api][:protocol] == "https" and node["roles"].include?("nova-multi-controller")
  Chef::Log.info("Configuring Nova-API to use SSL via Apache2+mod_wsgi")

  nova_package "api" do
    enable false
  end

  # Prepare Apache2 SSL vhost template:
  template "#{node[:apache][:dir]}/sites-available/openstack-nova.conf" do
    if node.platform == "suse"
      path "#{node[:apache][:dir]}/vhosts.d/openstack-nova.conf"
    end
    source "nova-apache-ssl.conf.erb"
    variables(
      :nova_apis => {"ec2" => {:port => node[:nova][:api][:ec2_port]},
                     "osapi_compute" => {:port => node[:nova][:api][:osapi_compute_port]},
                     "osapi_volume" => {:port => node[:nova][:api][:osapi_volume_port]},
                     "metadata" => {:port => node[:nova][:api][:metadata_port]}}
    )
    mode 0644
    if node.platform == "suse"
      notifies :reload, resources(:service => "apache2"), :immediately
    end
  end

  apache_site "openstack-nova.conf" do
    enable true
  end

  template "/etc/logrotate.d/openstack-nova-api" do
    source "nova.logrotate.erb"
    mode 0644
    owner "root"
    group "root"
  end
else
  # Remove potentially left-over Apache2 config files:
  if node.platform == "suse"
    vhost_config = "#{node[:apache][:dir]}/vhosts.d/openstack-nova.conf"
  else
    vhost_config = "#{node[:apache][:dir]}/sites-available/openstack-nova.conf"
  end
  if ::File.exist?(vhost_config)
    apache_site "openstack-nova.conf" do
      enable false
    end

    file vhost_config do
      action :delete
    end if node.platform != "suse"

    file "/etc/logrotate.d/openstack-nova-api" do
      action :delete
    end
  end
  # End of Apache2 vhost cleanup

  nova_package "api" do
    enable true
  end
end

env_filter = " AND keystone_config_environment:keystone-config-#{node[:nova][:keystone_instance]}"
keystones = search(:node, "recipes:keystone\\:\\:server#{env_filter}") || []
if keystones.length > 0
  keystone = keystones[0]
  keystone = node if keystone.name == node.name
else
  keystone = node
end

keystone_host = keystone[:fqdn]
keystone_protocol = keystone["keystone"]["api"]["protocol"]
keystone_token = keystone["keystone"]["service"]["token"]
keystone_service_port = keystone["keystone"]["api"]["service_port"]
keystone_admin_port = keystone["keystone"]["api"]["admin_port"]
keystone_service_tenant = keystone["keystone"]["service"]["tenant"]
keystone_service_user = "nova" # GREG: Fix this
keystone_service_password = "fredfred" # GREG: Fix this
Chef::Log.info("Keystone server found at #{keystone_host}")

template "/etc/nova/api-paste.ini" do
  source "api-paste.ini.erb"
  owner node[:nova][:user]
  group "root"
  mode "0640"
  variables(
    :keystone_protocol => keystone_protocol,
    :keystone_host => keystone_host,
    :keystone_admin_token => keystone_token,
    :keystone_service_port => keystone_service_port,
    :keystone_service_tenant => keystone_service_tenant,
    :keystone_service_user => keystone_service_user,
    :keystone_service_password => keystone_service_password,
    :keystone_admin_port => keystone_admin_port
  )
  # https is only used on the nova-multi-controller
  if node[:nova][:api][:protocol] == "https" and node["roles"].include?("nova-multi-controller")
    if ::File.symlink?("#{node[:apache][:dir]}/sites-enabled/openstack-nova.conf") or node.platform == "suse"
      notifies :reload, resources(:service => "apache2")
    end
  else
    notifies :restart, resources(:service => "nova-api"), :immediately
  end
end

# we only need to register the api on the controller, since this recipe is
# also used for setting up the metadata api on compute nodes
if node["roles"].include?("nova-multi-controller")

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
  if api[:crowbar][:public_name].nil? and node[:nova][:api][:protocol] != "https"
     public_api_host = Chef::Recipe::Barclamp::Inventory.get_network_by_type(api, "public").address
  else
     public_api_host = api[:crowbar][:public_name].nil? ? 'public.'+api[:fqdn] : api[:crowbar][:public_name]
  end
  admin_api_host = api[:fqdn]
  api_protocol = node[:nova][:api][:protocol]

  keystone_register "nova api wakeup keystone" do
    protocol keystone_protocol
    host keystone_host
    port keystone_admin_port
    token keystone_token
    action :wakeup
  end

  keystone_register "register nova user" do
    protocol keystone_protocol
    host keystone_host
    port keystone_admin_port
    token keystone_token
    user_name keystone_service_user
    user_password keystone_service_password
    tenant_name keystone_service_tenant
    action :add_user
  end

  keystone_register "give nova user access" do
    protocol keystone_protocol
    host keystone_host
    port keystone_admin_port
    token keystone_token
    user_name keystone_service_user
    tenant_name keystone_service_tenant
    role_name "admin"
    action :add_access
  end

  keystone_register "register nova service" do
    protocol keystone_protocol
    host keystone_host
    port keystone_admin_port
    token keystone_token
    service_name "nova"
    service_type "compute"
    service_description "Openstack Nova Service"
    action :add_service
  end

  keystone_register "register ec2 service" do
    protocol keystone_protocol
    host keystone_host
    port keystone_admin_port
    token keystone_token
    service_name "ec2"
    service_type "ec2"
    service_description "EC2 Compatibility Layer"
    action :add_service
  end

  keystone_register "register nova endpoint" do
    protocol keystone_protocol
    host keystone_host
    port keystone_admin_port
    token keystone_token
    endpoint_service "nova"
    endpoint_region "RegionOne"
    endpoint_publicURL "#{api_protocol}://#{public_api_host}:8774/v2/$(tenant_id)s"
    endpoint_adminURL "#{api_protocol}://#{admin_api_host}:8774/v2/$(tenant_id)s"
    endpoint_internalURL "#{api_protocol}://#{admin_api_host}:8774/v2/$(tenant_id)s"
#   endpoint_global true
#   endpoint_enabled true
    action :add_endpoint_template
  end

  keystone_register "register nova ec2 endpoint" do
    protocol keystone_protocol
    host keystone_host
    port keystone_admin_port
    token keystone_token
    endpoint_service "ec2"
    endpoint_region "RegionOne"
    endpoint_publicURL "#{api_protocol}://#{public_api_host}:8773/services/Cloud"
    endpoint_adminURL "#{api_protocol}://#{admin_api_host}:8773/services/Admin"
    endpoint_internalURL "#{api_protocol}://#{admin_api_host}:8773/services/Cloud"
#   endpoint_global true
#   endpoint_enabled true
    action :add_endpoint_template
  end
end
