#!/usr/bin/env ruby
require 'yaml'
require 'pp'
require 'optparse'
require 'json'
require 'aws-sdk-secretsmanager'
require 'base64'
require 'vault'
#require 'httpclient'
# Declare a global variable to hold variables
$final_variables = {}
$error_count = 0

# A set of allowed values for environment and regions
# This would need to be actively maintained
allowed_environment_types = ['nbs-obc-dev', 'nbs-obc-mctc', 'nbs-obc-test', 'nbs-obc-pt']
allowed_virtual_environment_types = ['nbs-obc-dev', 'nbs-obc-playground', 'nbs-obc-st1','nbs-obc-st2','nbs-obc-as-dev','nbs-obc-as-st','nbs-obc-devops-test', 'nbs-obc-as-pt']
allowed_aws_regions = ['eu-west-2']

# Set options
options = {'environmentconfig' => nil, 'clustername' => nil, 'envregion' => nil, 'vaultnamespace' => nil, 'virtualenv' => nil,'vaulttoken' => nil}

parser = OptionParser.new do|opts|
  opts.banner = "Usage: tokeniser_iac.rb [options]"

  opts.on('-e', '--environmentconfig environmentconfig', 'Path to file containing environment specific config values') do |environmentconfig|
    options['environmentconfig'] = environmentconfig;
  end

  opts.on('-n', '--cluster-name clustername', 'Name of the cluster environment') do |clustername|
    options['clustername'] = clustername;
  end

  opts.on('-r', '--env-region envregion', 'Region of the environment') do |envregion|
    options['envregion'] = envregion;
  end

  opts.on('-v', '--vault-namespace vaultnamespace', 'Namespace for vault in the environment') do |vaultnamespace|
    options['vaultnamespace'] = vaultnamespace;
  end

  opts.on('-l', '--virtual-env virtualenv', 'Name of the virtual environment name (to fetch relevant secrets)') do |virtualenv|
    options['virtualenv'] = virtualenv;
  end

  opts.on('-t', '--vault-token vaulttoken', 'Vault Token') do |vaulttoken|
    options['vaulttoken'] = vaulttoken;
  end
    
  opts.on('-h', '--help', 'Displays Help') do
    puts opts
    exit 2
  end
end

parser.parse!
# End of option parser

# Check if options are being passed
if options['environmentconfig'] == nil || options['envregion'] == nil || options['vaultnamespace'] == nil || options['clustername'] == nil || options['vaulttoken'] == nil
  puts "Please supply the path of project specific config files, env region, vault namespace, cluster name, vault token and (optionally, if using as part of a deployment pipeline) a virtual environment name."
  exit 2
end

E_REGION = options['envregion'].downcase
V_NAMESPACE = options['vaultnamespace']
V_TOKEN = options['vaulttoken']

E_NAME = options['clustername'].downcase
unless allowed_environment_types.include?("#{E_NAME}")
  puts "Cluster environment name #{E_NAME} is not valid, only #{allowed_environment_types} allowed"
  exit 2
end

if options['virtualenv'] != nil
  envType = "virtual"
  VENV_NAME = options['virtualenv'].downcase
  unless allowed_virtual_environment_types.include?("#{VENV_NAME}")
    puts "Virtual environment name #{E_NAME} is not valid, only #{allowed_environment_types} allowed"
    exit 2
  end
else
  envType = "cluster"
end

#E_REGION = ENV_REGION.downcase
#E_NAME.strip!
E_REGION.strip!

unless allowed_aws_regions.include?("#{E_REGION}")
  puts "Region #{E_REGION} is not valid, only #{allowed_aws_regions} allowed"
  exit 2
end
# End of sanity checks on options

# Function to parse config to find list of directories
def get_directories(config)
  list_of_directories = []
  config.each do |values|
    if values['directories'] != nil
      values['directories'].each do |directory|
        list_of_directories << directory
      end
    end
  end
  return list_of_directories
end

# Function to get list of files that needs to be templated
def get_files(directories, envType)
  list_of_files = []
  directories.each do |directory|
    if envType == "cluster"
      file_names = `find #{directory} -name *.secrettemplate -type f`.split()
    else #virtual
      file_names = `find #{directory} -name *.template -type f`.split()
    end
    file_names.each do |file|
      list_of_files << file
    end
  end
  return list_of_files
end

def replace_tokens(files, envType)
  text = ''
  files.each do |file_name|
    file_name.strip!
    pp "Processing #{file_name}"
    if envType == "cluster"
      actual_name, _extension = file_name.split(/\.secrettemplate$/)
    else #virtual
      actual_name, _extension = file_name.split(/\.template$/)
    end
    text = File.read(file_name)
    $final_variables.each do |string_to_replace, value|
      replacement_value = value.to_s
      if !ENV[string_to_replace].nil?
        replacement_value = ENV[string_to_replace].to_s
      end
      pp "Replacing value for #{string_to_replace}"
      if envType == "cluster"
        text.gsub!(/\£\{#{string_to_replace}\}/, replacement_value)
      else #virtual
        text.gsub!(/\$\{#{string_to_replace}\}/, replacement_value)
      end
    end
    if envType == "cluster"
      $error_count = $error_count + 1 if text.match(/\£\{.*?\}/m)
    else #virtual
      $error_count = $error_count + 1 if text.match(/\$\{.*?\}/m)
    end
    File.open(actual_name, "w") {|file| file.write text }
  end
end

def split_config(config, envsplit, regionsplit)
  config.each do |environment|
    if environment['environment']
      if environment['environment'].downcase == "#{envsplit}"
        if environment['region']
          environment['region'].each do |region|
            if region["#{regionsplit}"]
              region["#{regionsplit}"].each do |variable, value|
                variable = +variable.to_s
                value = +value.to_s
                if value.sub!(/\ASECRET_/, "")
                  value = get_value_from_vault(variable, envsplit)
                end
                $final_variables[variable] = value
              end
            end
          end
        end
      end
    end
  end
end


def vault_read(path)
  # vault_jenkins_token=get_value_from_secret_manager("secret-id-token", "cluster")
  # vault_jenkins_role_id=get_value_from_secret_manager("role-id", "cluster")
  # secret_id=%x{curl -s -k --header "X-Vault-Token: #{vault_jenkins_token}" --request POST https://vault.aws.nbscloud.co.uk/v1/#{V_NAMESPACE}/auth/approle/role/cicd-approle-role/secret-id | jq -r '.data.secret_id'}
  # vault_tmp_token=%x{vault write -namespace=#{V_NAMESPACE} -field=token auth/approle/login role_id=#{vault_jenkins_role_id} secret_id=#{secret_id}}
  vault_secret=%x{curl -s -k --header "X-Vault-Token: #{V_TOKEN}" --request GET https://vault.aws.nbscloud.co.uk/v1/#{V_NAMESPACE}/secrets/data/iac-secrets/#{E_NAME} | jq -r '.data.data.#{path}'}
  return vault_secret.strip!
end

def vault_read_virtualenv(path, virtualEnv)
  vault_jenkins_token=get_value_from_secret_manager("secret-id-token", "virtual")
  vault_jenkins_role_id=get_value_from_secret_manager("role-id", "virtual")
  secret_id=%x{curl -s -k --header "X-Vault-Token: #{vault_jenkins_token}" --request POST https://vault.aws.nbscloud.co.uk/v1/#{V_NAMESPACE}/auth/approle/role/cicd-terraform-approle-role/secret-id | jq -r '.data.secret_id'}
  vault_tmp_token=%x{vault write -namespace=#{V_NAMESPACE} -field=token auth/approle/login role_id=#{vault_jenkins_role_id} secret_id=#{secret_id}}
  #Mapping for secret name to path in vault
  vaultPaths = {
    "RULES_BASIC_AUTH_USR" => "rules.basic.auth.cred.user",
    "RULES_BASIC_AUTH_PASS" => "rules.basic.auth.cred.pass",
    "DATALOAD_BASIC_AUTH_USR" => "dataloading.basic.auth.cred.user",
    "DATALOAD_BASIC_AUTH_PASS" => "dataloading.basic.auth.cred.pass",
    "REDIS_PASSWORD" => "redis.password"
  }
  if path.include?("RULES")
    vault_secret=%x{curl -s -k --header "X-Vault-Token: #{vault_tmp_token}" --request GET  https://vault.aws.nbscloud.co.uk/v1/#{V_NAMESPACE}/#{E_NAME}/kv-#{virtualEnv}/data/rulesapi | jq -r '.data.data."#{vaultPaths[path]}"'}
  elsif path.include?("DATALOAD") || path.include?("REDIS")
    vault_secret=%x{curl -s -k --header "X-Vault-Token: #{vault_tmp_token}" --request GET  https://vault.aws.nbscloud.co.uk/v1/#{V_NAMESPACE}/#{E_NAME}/kv-#{virtualEnv}/data/cop-us-dataloading | jq -r '.data.data."#{vaultPaths[path]}"'}
  end
  return vault_secret.strip!
end

def get_value_from_vault(path, envName)
  #List of secrets which are dependent on virtual environment name to be fetched properly
  deploymentSecrets = ['RULES_BASIC_AUTH_USR', 'RULES_BASIC_AUTH_PASS', 'DATALOAD_BASIC_AUTH_USR', 'DATALOAD_BASIC_AUTH_PASS', 'REDIS_PASSWORD']
  #Handling secrets from virtual environment namespace
  if deploymentSecrets.include?("#{path}")
    path = path
    vault_data=vault_read_virtualenv(path, envName) # passing path and virtual env name
    return vault_data
  end
  #Secrets from IAC config
  path = path
  vault_data=vault_read(path)
  return vault_data
end

def get_value_from_secret_manager(secret_key_name, clusterType)
  if clusterType == "cluster"
    secret_name = "vault-cicd-approle"
  else #virtual
    secret_name = "vault-cicd-terraform-approle"
  end
  region_name = E_REGION
  client = Aws::SecretsManager::Client.new(region: region_name)

  begin
    get_secret_value_response = client.get_secret_value(secret_id: secret_name)
  rescue Aws::SecretsManager::Errors::DecryptionFailure => e
    # Secrets Manager can't decrypt the protected secret text using the provided KMS key.
    # Deal with the exception here, and/or rethrow at your discretion.
    raise "Error fetching value from Secrets Manager - Secrets Manager can't decrypt the protected secret text using the provided KMS key."
  rescue Aws::SecretsManager::Errors::InternalServiceError => e
    # An error occurred on the server side.
    # Deal with the exception here, and/or rethrow at your discretion.
    raise "An error occurred on the AWS server side."
  rescue Aws::SecretsManager::Errors::InvalidParameterException => e
    # You provided an invalid value for a parameter.
    # Deal with the exception here, and/or rethrow at your discretion.
    raise "Error fetching value from Secrets Manager - Invalid value for a parameter."
  rescue Aws::SecretsManager::Errors::InvalidRequestException => e
    # You provided a parameter value that is not valid for the current state of the resource.
    # Deal with the exception here, and/or rethrow at your discretion.
    raise "Error fetching value from Secrets Manager - A parameter value that is not valid for the current state of the resource was provided."
  rescue Aws::SecretsManager::Errors::ResourceNotFoundException => e
    # We can't find the resource that you asked for.
    # Deal with the exception here, and/or rethrow at your discretion.
    raise "Error fetching value from Secrets Manager - Resource not found."
  else
    # This block is ran if there were no exceptions.

    # Decrypts secret using the associated KMS CMK.
    # Depending on whether the secret is a string or binary, one of these fields will be populated.
    if get_secret_value_response.secret_string
      secret = get_secret_value_response.secret_string
    else
      decoded_binary_secret = Base64.decode64(get_secret_value_response.secret_binary)
    end
    #return decoded_binary_secret
    obj = JSON.parse(secret)
    #return secret
    return obj["#{secret_key_name}"]
  end
end

# Load YAML file into variables
environment_variables = YAML.load(File.read("#{options['environmentconfig']}"))
# Read variables in order so that we can overwrite as needed
# Read common first and then environment and region specific
split_config(environment_variables, '*', '*')
split_config(environment_variables, '*', E_REGION)
if envType == "cluster" #Cluster environment (IAC)
  split_config(environment_variables, E_NAME, '*')
  split_config(environment_variables, E_NAME, E_REGION)
else #Virtual environment (deployment)
  split_config(environment_variables, VENV_NAME, '*')
  split_config(environment_variables, VENV_NAME, E_REGION)
end

# Read the list of directories provided in the config
list_of_directories = get_directories(environment_variables)

list_of_files = get_files(list_of_directories, envType)
# Do the actual replacement
replace_tokens(list_of_files, envType)