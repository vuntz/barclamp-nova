# Copyright 2011, Dell 
# 
# Licensed under the Apache License, Version 2.0 (the "License"); 
# you may not use this file except in compliance with the License. 
# You may obtain a copy of the License at 
# 
#  http://www.apache.org/licenses/LICENSE-2.0 
# 
# Unless required by applicable law or agreed to in writing, software 
# distributed under the License is distributed on an "AS IS" BASIS, 
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
# See the License for the specific language governing permissions and 
# limitations under the License. 
# 

class NovaController < BarclampController
  def initialize
    @service_object = NovaService.new logger
  end
  
  def node_disks
    disk_list = {}
    name = params[:id] || params[:name]
    # by default, the named that is passed (by _edit_attributes.html.haml) is
    # the alias, and if no alias exists, it's the name of the node
    node = NodeObject.find_node_by_alias(name)
    if node.nil?
      node = NodeObject.find_node_by_name(name)
    end
    if not node.nil?
      node["crowbar"]["disks"].each do | disk, data |
        unless data["usage"] != "Storage" or data["size_bytes"].nil?
	  size_gb = data["size_bytes"].to_f / (1000**3)
	  if size_gb >= 0.1
            disk_list[disk] = sprintf("%#1.1f", size_gb)
	  end
	end
      end
    end
    Rails.logger.info "disk list #{disk_list.inspect}"
    render :json => JSON.generate(disk_list)
  end
end

