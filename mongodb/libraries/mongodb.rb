require 'json'

class Chef::ResourceDefinitionList::MongoDB

  def self.configure_replicaset(node, name, members)
    # lazy require, to move loading this modules to runtime of the cookbook
    require 'rubygems'
    require 'mongo'
    
    if members.length == 0
      abort("cannot configure replicaset '#{name}', no member nodes found")
    end
    
    begin
      connection = Mongo::Connection.new('localhost', node['mongodb']['port'], :op_timeout => 5, :slave_ok => true)
    rescue
      Chef::Log.warn("Could not connect to database: 'localhost:#{node['mongodb']['port']}'")
      return
    end
    
    members.sort!{ |x,y| x['name'] <=> y['name'] }
    rs_members = []
    members.each_index do |n|
      port = members[n]['mongodb']['port']
      rs_members << {"_id" => n, "host" => "#{members[n]['ipaddress']}:#{port}"}
    end
    
    admin = connection['admin']
    cmd = BSON::OrderedHash.new
    cmd['replSetInitiate'] = {
        "_id" => name,
        "members" => rs_members
    }
    
    begin
      result = admin.command(cmd, :check_response => false)
    rescue Mongo::OperationTimeout
      Chef::Log.info("Started configuring the replicaset, this will take some time, another run should run smoothly")
      return
    end
    if result.fetch("ok", nil) == 1:
      # everything is fine, do nothing
    elsif result.fetch("errmsg", nil) == "already initialized"
      # check if both configs are the same
      config = connection['local']['system']['replset'].find_one({"_id" => name})
      if config['_id'] == name and config['members'] == rs_members
        Chef::Log.info("Replicaset '#{name}' already configured")
      else
        # remove removed members from the replicaset and add the new ones
        rs_members.collect!{ |member| member['host'] }
        config['version'] += 1
        old_members = config['members'].collect{ |member| member['host'] }
        members_delete = old_members - rs_members        
        config['members'] = config['members'].delete_if{ |m| members_delete.include?(m['host']) }
        members_add = rs_members - old_members
        max_id = config['members'].collect{ |member| member['_id']}.max
        members_add.each do |m|
          max_id += 1
          config['members'] << {"_id" => max_id, "host" => m}
        end
        
        rs_connection = Mongo::ReplSetConnection.new( *old_members.collect{ |m| m.split(":") })
        admin = rs_connection['admin']
        
        cmd = BSON::OrderedHash.new
        cmd['replSetReconfig'] = config
        begin
          result = admin.command(cmd, :check_response => false)
        rescue Mongo::ConnectionFailure
          # reconfiguring destroys exisiting connections, reconnect
          Mongo::Connection.new('localhost', node['mongodb']['port'], :op_timeout => 5, :slave_ok => true)
          config = connection['local']['system']['replset'].find_one({"_id" => name})
          Chef::Log.info("New config successfully applied: #{config.inspect}")
        end
      end
    elsif !result.fetch("errmsg", nil).nil?
      Chef::Log.error("Failed to configure replicaset, reason: #{result.inspect}")
    end
  end
  
  def self.configure_shards(node, shard_nodes)
    # lazy require, to move loading this modules to runtime of the cookbook
    require 'rubygems'
    require 'mongo'
    
    shard_members = shard_nodes.collect do |n|
      # the docs are not exact enough, do sgards which are replicasets need special handling?
      "#{n['ipaddress']}:#{n['mongodb']['port']}"
    end
    Chef::Log.info(shard_members.inspect)
    
    begin
      connection = Mongo::Connection.new('localhost', node['mongodb']['port'], :op_timeout => 5)
    rescue Exception => e
      Chef::Log.warn("Could not connect to database: 'localhost:#{node['mongodb']['port']}', reason #{e}")
      return
    end
    
    admin = connection['admin']
    
    shard_members.each do |shard|
      cmd = BSON::OrderedHash.new
      cmd['addShard'] = shard
      begin
        result = admin.command(cmd, :check_response => false)
      rescue Mongo::OperationTimeout
        result = "Adding shard '#{shard}' timed out, run the recipe again to check the result"
      end
      Chef::Log.info(result.inspect)
    end
  end
  
  def self.configure_sharded_collections(node, sharded_collections)
    # lazy require, to move loading this modules to runtime of the cookbook
    require 'rubygems'
    require 'mongo'
    
    begin
      connection = Mongo::Connection.new('localhost', node['mongodb']['port'], :op_timeout => 5)
    rescue Exception => e
      Chef::Log.warn("Could not connect to database: 'localhost:#{node['mongodb']['port']}', reason #{e}")
      return
    end
    
    admin = connection['admin']
    
    databases = sharded_collections.keys.collect{ |x| x.split(".").first}.uniq
    Chef::Log.info("enable sharding for these databases: '#{databases.inspect}'")
    
    databases.each do |db_name|
      cmd = BSON::OrderedHash.new
      cmd['enablesharding'] = db_name
      begin
        result = admin.command(cmd, :check_response => false)
      rescue Mongo::OperationTimeout
        result = "enable sharding for '#{db_name}' timed out, run the recipe again to check the result"
      end
      Chef::Log.info(result.inspect)
    end
    
    sharded_collections.each do |name, key|
      cmd = BSON::OrderedHash.new
      cmd['shardcollection'] = name
      cmd['key'] = {key => 1}
      begin
        result = admin.command(cmd, :check_response => false)
      rescue Mongo::OperationTimeout
        result = "sharding '#{db_name}' on key '#{key}' timed out, run the recipe again to check the result"
      end
      Chef::Log.info(result.inspect)
    end
  
  end
  
end
