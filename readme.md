# Nexus2Artifactory
*Author: thomas.w.curry* <br>
*Version: 1.0* <br>
*Date: 25/0/20* <br>
## Introduction
Nexus2Artifactory is a simple tool that can be used to migrate a Nexus repository to an Artifactory repository. The tool is written as a Python script (compatible with version 3.7.1 and higher) and is configured using a properties file, which sets out what repositories will be migrated.
## Usage
The tool is run using the following syntax:<br><br>
```py nexus2artifactory.py path/to/properties/file multithreading action```
#### Parameters
* **propertiesFilePath** [REQUIRED]: Path to the properties file. e.g. ./nexus2artifactory-properties.json
* **multithreading** [REQUIRED]: Whether to use multithreading or not. This provides (some) performance boost for large repos, but is less stable. Allowed values:
    * true: enable multithreading
    * false: disable multithreaduing
* **action** [OPTIONAL]: The action the script will perform. This allows the functions of the script to be performed at separate times, e.g. not perform a full transfer, rather perform part of the transfer. Allowed values:
    * full: Perform a full transfer from Nexus to Artifactory. The default if *action* is not specified.
    * download: Download the repo from Nexus to the local machine. Also generates an asset paths definition file (assetPaths.json) which is needed for uploading to Artifactory at a later time.
    * upload: Upload the locally stored repo to Artifactory. Requires the asset paths definition file created from a download operation.
    * clean: Clean the locally stored data.
### Pre-requisites
The secrets that are needed for accessing Nexus and Artifactory must be stored in secrets manager. Therefore this script also needs to be run in a context that has access to those secrets (either being run a machine that has and access key set up and entered using aws configure, or by an IAM role). The properties file must be created before execution.
### Properties File
#### Format:
* **nexusConfig**
    * **url** (string): URL of Nexus
    * **repos** (list): List of names of Nexus repositories to transfer
    * **fileNameFilterRegex** (map of repoName (string), regex (string)): Filters for selecting which files from a repo to upload. Dictionary with (Nexus) repository names as keys, and regex strings as values. For example, `"releases": ".+ob-common.+"` means that when the repo ("releases") is being fetched, only filenames that match the regex `".+ob-common.+"` (contains "ob-common") are transferred.
    * **credentialConfig**: Object that stores details needed to fetch Nexus credentials
        * **secretArn** (string): ARN that points to AWS Secrets Manager secret that contains the Nexus credentials
        * **usernamePath** (string): The path to the username value in the Secrets Manager secret where the Nexus credentials are stored.
        * **passwordPath** (string): The path to the password value in the Secrets Manager secret where the Nexus credentials are stored.
* **artifactoryConfig**
    * **url** (string): URL of Artifactory
    * **repos** (list): List of names of Artifactory repositories to transfer corresponding Nexus repositories to. The order matters, the first repo in nexusConfig.repos will be transferred to the the first repo in this list (artifactoryConfig.repos).
    * **credentialConfig** : Object that stores details needed to fetch Artifactory credentials
        * **secretArn** (string): ARN that points to AWS Secrets Manager secret that contains the Artifactory credentials
        * **usernamePath** (string): The path to the username value in the Secrets Manager secret where the Artifactory credentials are stored.
        * **passwordPath** (string): The path to the password value in the Secrets Manager secret where the Artifactory credentials are stored.
#### Example:
``` json
{
    "nexusConfig": {
        "url": "http://devops.obphoenix.co.uk/nexus/",
        "repos": [
            "releases",
            "apigee-proxy"
        ],
        "fileNameFilterRegex":{
                "releases": ".+fileNameRegexToMatchToTransfer.+"
            },
        "credentialConfig": {
            "secretArn": "arn:aws:secretsmanager:eu-west-2:xxxxxxxxxxxx:secret:nexus-creds-xxxxxx",
            "usernamePath": "userName",
            "passwordPath": "password"
        }
    },
    "artifactoryConfig": {
        "url": "http://192.168.1.216:8082/artifactory/",
        "repos": [
            "example-repo-local",
            "example-repo-local2"
        ],
        "credentialConfig": {
            "secretArn": "arn:aws:secretsmanager:eu-west-2:xxxxxxxxxxxx:secret:artifactory-creds-xxxxxx",
            "usernamePath": "username",
            "passwordPath": "password"
        }
    }
}
```
