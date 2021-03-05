import os, sys, json, requests, urllib3, boto3, shutil, re, time, threading, signal
import concurrent.futures
from concurrent.futures import wait
from multiprocessing import Pool

assetPaths = []
multiRepoAssetPaths = {}
backoffDict = {}

def main():
    action = "full"
    try:
        propertiesFilePath = sys.argv[1]
        multiThreading = sys.argv[2]
        if not(multiThreading == "true") and not(multiThreading == "false"):
            print(f"Invalid value for multithreading parameter \"{multiThreading}\" - valid values are 'true' and 'false'.")
            sys.exit(1)
        if propertiesFilePath == "--help":
            displayUsage()
            sys.exit(0)
        if len(sys.argv) == 4:
            action = sys.argv[3]
        else:
            print("No action specified - defaulting to full transfer of repositories.")
    except Exception as e:
        print(f"Error - invalid parameters: {e}")
        displayUsage()
        sys.exit(1)
    try:
        print("Reading properties file...")
        f = open(propertiesFilePath, "r")
        properties = json.loads(f.read())
        f.close()
        nexusUrl = properties["nexusConfig"]["url"]
        nexusRepos = properties["nexusConfig"]["repos"]
        fileNameFilter = properties["nexusConfig"]["fileNameFilterRegex"]
        nexusCredentialConfig = properties["nexusConfig"]["credentialConfig"]
        artifactoryUrl = properties["artifactoryConfig"]["url"]
        artifactoryRepos = properties["artifactoryConfig"]["repos"]
        artifactoryCredentialConfig = properties["artifactoryConfig"]["credentialConfig"]
        print("Successfully read properties file.")
    except Exception as e:
        print(f"Fatal error: Couldn't read properties file or properties file missing value - {e}.")
        sys.exit(1)

    print("Fetching credentials from Secrets Manager...")
    nexusCreds = fetchSecret(nexusCredentialConfig)
    artifactoryCreds = fetchSecret(artifactoryCredentialConfig)
    print("Successfully fetched credentials from Secrets Manager.")

    for i in range(len(nexusRepos)):
        if action == "full":
            print(f"--------------------- Transferring Nexus repo '{nexusRepos[i]}' to '{artifactoryRepos[i]}' in Artifactory ---------------------")
            repoItems = getRepoItems(nexusUrl, nexusRepos[i], nexusCreds["username"], nexusCreds["password"], fileNameFilter)
            downloadItems(repoItems, nexusCreds["username"], nexusCreds["password"], nexusRepos[i], fileNameFilter, multiThreading)
            uploadItems(artifactoryUrl, nexusRepos[i], artifactoryRepos[i], artifactoryCreds["username"], artifactoryCreds["password"], multiThreading)
            deleteLocalItems(nexusRepos[i])
        elif action == "download":
            print(f"--------------------- Downloading Nexus repo '{nexusRepos[i]}' ---------------------")
            repoItems = getRepoItems(nexusUrl, nexusRepos[i], nexusCreds["username"], nexusCreds["password"], fileNameFilter)
            downloadItems(repoItems, nexusCreds["username"], nexusCreds["password"], nexusRepos[i], fileNameFilter, multiThreading)
            multiRepoAssetPaths[nexusRepos[i]] = json.dumps(assetPaths)
        elif action == "upload":
            print(f"--------------------- Uploading '{nexusRepos[i]}' to Artifactory repo '{artifactoryRepos[i]}' ---------------------")
            readAssetPathsDefinition(nexusRepos[i])
            uploadItems(artifactoryUrl, nexusRepos[i], artifactoryRepos[i], artifactoryCreds["username"], artifactoryCreds["password"], multiThreading)
            #deleteLocalItems(nexusRepos[i])
        elif action == "clean":
            print(f"--------------------- Clearing the '{nexusRepos[i]}' from local workspace ---------------------")
            deleteLocalItems(nexusRepos[i])
        else:
            print(f"Invalid action '{action}'.")
            displayUsage()
            sys.exit(1)
        assetPaths.clear()

    if action == "download":
        createAssetPathsDefinition()
    elif action == "clean":
        os.remove("assetPaths.json")
        shutil.rmtree("nexusRepo")
    elif action == "full":
        shutil.rmtree("nexusRepo")

    print("All repos transferred.")

def fetchSecret(secretConfig):
    try:
        client = boto3.client('secretsmanager')
        response = client.get_secret_value(SecretId=secretConfig["secretArn"])
        returnJson = json.loads(response["SecretString"])
        return {
            "username": returnJson[secretConfig["usernamePath"]],
            "password": returnJson[secretConfig["passwordPath"]]
        }
    except Exception as e:
        print(f"Could not fetch secret '{secretConfig['secretArn']}' - {e}")
        sys.exit(1)

def getRepoItems(nexusUrl, repoName, nexusUsername, nexusPassword, filterRegexDict):
    nexusUrl += f"/service/rest/v1/components?repository={repoName}"
    items = []
    moreDataToLoad = True
    continuationToken = ""
    requestCount = 0
    print(f"Begun fetching list of assets in {repoName}...")
    while moreDataToLoad:
        requestCount += 1
        try:
            if continuationToken == "": #Initial call
                r = requests.get(nexusUrl, auth=(nexusUsername, nexusPassword))
            else: #Using continuation token
                r = requests.get(nexusUrl+f"&continuationToken={continuationToken}", auth=(nexusUsername, nexusPassword))
            rawResponse = r.json()
            continuationToken = rawResponse["continuationToken"]
            if continuationToken == None:
                moreDataToLoad = False
            for item in rawResponse["items"]:
                items.append(item)
        except Exception as e:
            print(f"Error retrieving object list: {e}\nRetrying in 5 seconds...")
            time.sleep(5)
            requestCount -= 1 #So loop is correct
        print(f"Fetching list of items, {requestCount} requests made so far", end='\r')
    print("")
    #Create asset paths
    filterRegex =".*"
    for repo, regex in filterRegexDict.items():
        if repo == repoName:
            filterRegex = regex
    for item in items:
        for asset in item["assets"]:
            if re.match(filterRegex, asset["path"]):
                assetPaths.append(asset["path"])
    return items

def initializer():
    #Ignore CTRL+C in threads
    signal.signal(signal.SIGINT, signal.SIG_IGN)

def downloadItems(items, nexusUsername, nexusPassword, repoName, filterRegexDict, multiThreading):
    totalAssetNo = 0
    for item in items:
            for asset in item["assets"]:
                totalAssetNo += 1
    print(f"Beginning download of {totalAssetNo} assets, this will take a while...")
    filterRegex =".*"
    for repo, regex in filterRegexDict.items():
        if repo == repoName:
            filterRegex = regex
    # assetNo = 0
    data = []
    if multiThreading == "true":
        for item in items:
            data.append({
                "item": item,
                "filterRegex": filterRegex,
                "nexusUsername": nexusUsername,
                "nexusPassword": nexusPassword,
                "repoName" : repoName
            }) #Create item to hold data to pass to thread
        pool = Pool(5, initializer=initializer)
        try:
            pool.map(getItem, data)
        except KeyboardInterrupt:
            pool.terminate()
    else:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning) #Disable warnings (which occur since we're using self-signed certs)
        assetNo = 0
        for item in items:
            for asset in item["assets"]:
                print(f"Fetching assets, fetched {assetNo} assets so far...", end='\r')
                try:
                    url = asset["downloadUrl"]
                    if re.match(filterRegex, asset["path"]):
                        r = requests.get(url, auth=(nexusUsername, nexusPassword), verify=False)
                        filename = f"nexusRepo/{repoName}/{asset['path']}"
                        os.makedirs(os.path.dirname(filename), exist_ok=True)
                        f = open(filename, "wb")
                        f.write(r.content)
                        f.close()
                        assetNo += 1
                except Exception as e:
                    print("")
                    print(f"Warning: Could not fetch asset '{asset['path']}' - {e} Skipping...")
    print("")
    print(f"Asset download complete.")# Fetched {assetNo} assets.")

def getItem(data):
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning) #Disable warnings (which occur since we're using self-signed certs)
    item = data["item"]
    filterRegex = data["filterRegex"]
    nexusUsername = data["nexusUsername"]
    nexusPassword = data["nexusPassword"]
    repoName = data["repoName"]
    for asset in item["assets"]:
        for retryNo in range(11): # Attempts 10 retries
            if retryNo == 10:
                print(f"Thread {threading.get_ident()}: Error: Could not fetch asset '{asset['path']}' - {e}")
                sys.exit(1)
            print(f"Thread {threading.get_ident()}: Fetching asset {asset['path']}")
            try:
                url = asset["downloadUrl"]
                if re.match(filterRegex, asset["path"]):
                    assetPaths.append(asset["path"])
                    r = requests.get(url, auth=(nexusUsername, nexusPassword), verify=False)
                    #r.encoding = "utf-8"
                    filename = f"nexusRepo/{repoName}/{asset['path']}"
                    os.makedirs(os.path.dirname(filename), exist_ok=True)
                    f = open(filename, "wb")
                    f.write(r.content)
                    f.close()
                    print(f"Thread {threading.get_ident()}: Successfully fetched asset {asset['path']}")
                    break
            except Exception as e:
                # print("")
                print(f"Thread {threading.get_ident()}: Warning: Could not fetch asset '{asset['path']}' - {e} Retrying...")
                time.sleep(5)

def uploadItems(artifactoryUrl, nexusRepoName, artifactoryRepoName, username, password, multiThreading):
    print(f"Beginning upload of {int(len(assetPaths))} assets...")
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning) #Disable warnings (which occur since we're using self-signed certs)
    uploadNo = 0
    if multiThreading == "true":
        uploadData = []
        for path in assetPaths:
            uploadData.append({
                "path": path,
                "nexusRepoName": nexusRepoName,
                "artifactoryUrl": artifactoryUrl,
                "artifactoryRepoName": artifactoryRepoName,
                "username": username,
                "password": password
            })
        uploadPool = Pool(5, initializer=initializer)
        try:
            uploadPool.map(pushItem, uploadData)
        except KeyboardInterrupt:
            uploadPool.terminate()
    else:
        for path in assetPaths:
            filePath = f"nexusRepo/{nexusRepoName}/{path}"
            try:
                if not(re.match(r".*.md5", path) or re.match(r".*.sha1", path)):
                    if not(re.match(r".*.pom", path)):
                        #f = open(filePath, "r", encoding="utf-8")
                        f = open(filePath, "rb")
                        fileContents = f.read()
                        f.close()
                        r = requests.put(f"{artifactoryUrl}/{artifactoryRepoName}/{path}", auth=(username, password), data=fileContents, verify=False)
                        if r.status_code > 199 and r.status_code < 300:
                            uploadNo += 1
                            print(f"Uploading assets, uploaded {uploadNo} assets so far...", end='\r')
                        else:
                            print(f"({r.status_code}) Could not upload item '{path}' to Artifactory - {r.text}.")
                    else:
                        f = open(filePath, "r", encoding="utf-8")
                        fileContents = f.read()
                        f.close()
                        r = requests.put(f"{artifactoryUrl}/{artifactoryRepoName}/{path}", auth=(username, password), data=fileContents.encode('utf-8'), verify=False)
                        uploadNo += 1
                        print(f"Uploading assets, uploaded {uploadNo} assets so far...", end='\r')
            except Exception as e:
                print(f"Could not upload item '{path}' to Artifactory - {e}. Skipping...")
    print("")
    print("Asset upload complete.")

def pushItem(data):
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    path = data["path"]
    nexusRepoName = data["nexusRepoName"]
    artifactoryUrl = data["artifactoryUrl"]
    artifactoryRepoName = data["artifactoryRepoName"]
    username = data["username"]
    password = data["password"]

    for retryNo in range(11): # Attempts 10 retries
        if retryNo == 10:
            print(f"Thread {threading.get_ident()}: Error: Could not upload item '{path}' to Artifactory.")
            sys.exit(1)
        filePath = f"nexusRepo/{nexusRepoName}/{path}"
        try:
            f = open(filePath, "r", encoding="utf-8")
            fileContents = f.read()
            f.close()
            print(f"Thread {threading.get_ident()}: Uploading {path}...")
            r = requests.put(f"{artifactoryUrl}/{artifactoryRepoName}/{path}", auth=(username, password), data=fileContents.encode('utf-8'), headers={"Connection": "close"}, verify=False)
            if int(r.status_code) < 200 or int(r.status_code) > 299:
                print(f"Thread {threading.get_ident()}: Could not upload item '{path}' to Artifactory - {r.text}. Retrying...")
            break
        except Exception as e:
            print(f"Thread {threading.get_ident()}: Could not upload item '{path}' to Artifactory - {e}. Retrying...")
            time.sleep(5)

def deleteLocalItems(repoName):
    for item in assetPaths:
        filePath = f"nexusRepo/{repoName}/{item}"
        os.remove(filePath)
    print(f"Deleted local files for {repoName}")

def createAssetPathsDefinition():
    f = open("assetPaths.json", "w")
    f.write(json.dumps(multiRepoAssetPaths))
    f.close()

def readAssetPathsDefinition(repoName):
    try:
        f = open("assetPaths.json", "r")
        jsonPaths = json.loads(json.loads(f.read())[repoName])
        f.close()
        for path in jsonPaths:
            assetPaths.append(path)
    except Exception as e:
        print(f"Could not read asset paths definition - {e}.\n\nPlease make sure there is a file called 'assetPaths.json' in the same directory as this script.")
        print("This will have been created when you ran the script to download before. It stores data about what paths to upload, and is neccesary to preserve the object structure when pushing to Artifactory.")
        sys.exit(1)

def displayUsage():
    print("\nUsage: py nexus2artifactory.py propertiesFilePath multithreading action")
    print("Arguments:")
    print("==========")
    print("propertiesFilePath: Path to properties file. Required.")
    print("multithreading: Whether to use multithreading or not. Accepted values: 'true' & 'false'. Required.")
    print("action: Action to perform. Accepted values: 'full', 'download' & 'upload'. Defaults to 'full'. Optional.")

if __name__ == "__main__":
    main()
