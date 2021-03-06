#!/usr/bin/env ruby

require 'aws-sdk'
require 'dotenv'
require 'pry'
require 'pg'

Dotenv.load

def redshift
  @redshift ||= Aws::Redshift::Client.new
end

def logging_cluster
  redshift.describe_clusters(cluster_identifier: ENV['CLUSTER_IDENTIFIER'])[:clusters].first
end

def cluster_available
  logging_cluster[:cluster_status] == 'available'
end

puts "CREATING REDSHIFT CLUSTER"

resp = redshift.create_cluster(
  db_name: ENV["DB_NAME"],
  # required
  cluster_identifier: ENV['CLUSTER_IDENTIFIER'],
  cluster_type: ENV['CLUSTER_TYPE'],
  #cluster_type: "multi-node",
  # required
  node_type: "dw2.large",
  # required
  master_username: ENV["REDSHIFT_USERNAME"],
  # required
  master_user_password: ENV["REDSHIFT_PASSWORD"],
  port: ENV["PORT"],
  number_of_nodes: ENV["NUMBER_OF_NODES"],
  publicly_accessible: true,
  encrypted: true
) unless cluster_available

until cluster_available do
  puts "Waiting for Cluster to be ready"
  sleep 10
end

redshift_host = logging_cluster[:endpoint][:address]

puts "HOST: #{redshift_host}"

puts "CONNECT TO DATABASE WITH FOLLOWING PSQL COMMAND (Take the password from .env file):"
puts "psql -h #{redshift_host} -U #{ENV['REDSHIFT_USERNAME']} -p #{ENV['PORT']} -d #{ENV['DB_NAME']}"

connection = PG.connect(host: redshift_host, user: ENV["REDSHIFT_USERNAME"], password: ENV['REDSHIFT_PASSWORD'], port: ENV["PORT"], dbname: ENV['DB_NAME'])

connection.exec("drop table if exists events;")

puts "CreatTable:start"

# Adding several message columns because tab is used as a separator
# by papertrail and some of our logs have tabs in them as well

connection.exec("CREATE TABLE events (
  id BIGINT SORTKEY NOT NULL,
  received_at_raw VARCHAR(25) NOT NULL,
  generated_at_raw VARCHAR(25) NOT NULL,
  source_id INT NOT NULL,
  source_name VARCHAR(128) ENCODE Text32k,
  source_ip VARCHAR(15) NOT NULL ENCODE Text32k,
  facility VARCHAR(8) NOT NULL ENCODE Text255,
  severity VARCHAR(9) NOT NULL ENCODE Text255,
  program VARCHAR(64) ENCODE Text32k,
  message VARCHAR(8192) DEFAULT NULL,
  message2 VARCHAR(8192) DEFAULT NULL,
  message3 VARCHAR(8192) DEFAULT NULL,
  message4 VARCHAR(8192) DEFAULT NULL,
  PRIMARY KEY(id))
  DISTSTYLE even;")

puts "CreatTable:finish"

puts "Events:start"

connection.exec("copy events from
  '#{ENV['S3_PATH']}'
  credentials 'aws_access_key_id=#{ENV['S3_AWS_ACCESS_KEY_ID']};aws_secret_access_key=#{ENV['S3_AWS_SECRET_ACCESS_KEY']}'
  delimiter '\t'
  gzip
  emptyasnull
  blanksasnull
  maxerror as 100000
  TRUNCATECOLUMNS
  ACCEPTINVCHARS AS '_'
  FILLRECORD;
")

puts "Events:finish"

puts "Vacuum:start"

connection.exec('vacuum;')

puts "Vacuum:finish"

puts "CONNECT TO DATABASE WITH FOLLOWING PSQL COMMAND (Take the password from .env file):"
puts "psql -h #{redshift_host} -U #{ENV['REDSHIFT_USERNAME']} -p #{ENV['PORT']} -d #{ENV['DB_NAME']}"
