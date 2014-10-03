#!/usr/bin/env ruby
#
# MySQL Replication Status (modded from disk)
# ===
#
# Copyright 2011 Sonian, Inc <chefs@sonian.net>
# Updated by Oluwaseun Obajobi 2014 to accept ini argument
#
# Released under the same terms as Sensu (the MIT license); see LICENSE
# for details.
#
# USING INI ARGUMENT
# This was implemented to load mysql credentials without parsing the username/password.
# The ini file should be readable by the sensu user/group.
# Ref: http://eric.lubow.org/2009/ruby/parsing-ini-files-with-ruby/
#
#   EXAMPLE
#     mysql-alive.rb -h db01 --ini '/etc/sensu/my.cnf'
#
#   MY.CNF INI FORMAT
#   [client]
#   user=sensu
#   password="abcd1234"
#

require 'rubygems' if RUBY_VERSION < '1.9.0'
require 'sensu-plugin/check/cli'
require 'mysql'
require 'inifile'

class CheckMysqlReplicationStatus < Sensu::Plugin::Check::CLI

  option :host,
    :short => '-h',
    :long => '--host=VALUE',
    :description => 'Database host'

  option :port,
    :short => '-P',
    :long => '--port=VALUE',
    :description => 'Database port',
    :default => 3306,
    :proc => lambda { |s| s.to_i }

  option :socket,
    :short => '-s SOCKET',
    :long => '--socket SOCKET',
    :description => "Socket to use"

  option :user,
    :short => '-u',
    :long => '--username=VALUE',
    :description => 'Database username'

  option :pass,
    :short => '-p',
    :long => '--password=VALUE',
    :description => 'Database password'

  option :ini,
    :short => '-i',
    :long => '--ini VALUE',
    :description => "My.cnf ini file"

  option :warn,
    :short => '-w',
    :long => '--warning=VALUE',
    :description => 'Warning threshold for replication lag',
    :default => 900,
    :proc => lambda { |s| s.to_i }

  option :crit,
    :short => '-c',
    :long => '--critical=VALUE',
    :description => 'Critical threshold for replication lag',
    :default => 1800,
    :proc => lambda { |s| s.to_i }

  VALID_STATUS = ['ok','warning','critical','unknown']
  option :not_slave_exit_method,
    :short => '-n',
    :long => '--not-slave=VALUE',
    :description => 'Exit method to use if not a slave. Default is ok',
    :default => 'ok',
    :proc => lambda { |s|
      if VALID_STATUS.include?(s)
        s
      else
        abort "Invalid for --not-slave: #{s.inspect}. " +
              "Expecting one of #{VALID_STATUS.join(', ')}."
      end
    }

  option :help,
    :short => "-h",
    :long => "--help",
    :description => "Check MySQL replication status",
    :on => :tail,
    :boolean => true,
    :show_options => true,
    :exit => 0

  def run
    if config[:ini]
      ini = IniFile.load(config[:ini])
      section = ini['client']
      db_user = section['user']
      db_pass = section['password']
    else
      db_user = config[:user]
      db_pass = config[:pass]
    end
    db_host = config[:host]

    if [db_host, db_user, db_pass].any? {|v| v.nil? }
      unknown "Must specify host, user, password"
    end

    begin
      db = Mysql.new(db_host, db_user, db_pass, nil, config[:port], config[:socket])
      results = db.query 'show slave status'

      unless results.nil?
        results.each_hash do |row|
          warn "couldn't detect replication status" unless
            ['Slave_IO_State',
              'Slave_IO_Running',
              'Slave_SQL_Running',
              'Last_IO_Error',
              'Last_SQL_Error',
              'Seconds_Behind_Master'].all? do |key|
                row.has_key? key
              end

          slave_running = %w[Slave_IO_Running Slave_SQL_Running].all? do |key|
            row[key] =~ /Yes/
          end

          output = "Slave not running!"
          output += " STATES:"
          output += " Slave_IO_Running=#{row['Slave_IO_Running']}"
          output += ", Slave_SQL_Running=#{row['Slave_SQL_Running']}"
          output += ", LAST ERROR: #{row['Last_SQL_Error']}"

          critical output unless slave_running

          replication_delay = row['Seconds_Behind_Master'].to_i

          message = "replication delayed by #{replication_delay}"

          if replication_delay > config[:warn] &&
              replication_delay <= config[:crit]
            warning message
          elsif replication_delay >= config[:crit]
            critical message
          else
            ok "slave running: #{slave_running}, #{message}"
          end

        end

        message "show slave status was nil. This server is not a slave."
        send config[:not_slave_exit_method] # exit with ok/warning/critical
      end

    rescue Mysql::Error => e
      errstr = "Error code: #{e.errno} Error message: #{e.error}"
      critical "#{errstr} SQLSTATE: #{e.sqlstate}" if e.respond_to?("sqlstate")

    rescue => e
      critical e

    ensure
      db.close if db
    end
  end

end
