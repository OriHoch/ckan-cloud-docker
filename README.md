# CKAN Cloud Docker

Contains Docker imgages for the different components of CKAN Cloud and a Docker compose environment for development and testing.

Available components:

* **cca-operator**: Kubernetes server-side component that manages the multi-tenant CKAN instances. see the [README](cca-operator/README.md) for more details.
* **ckan**: The CKAN app
* **db**: PostgreSQL database and management scripts
* **nginx**: Reverse proxy for the CKAN app
* **solr**: Solr search engine
* **jenkins**: Automation service
* **provisioning-api**: [ckan-cloud-provisioning-api](https://github.com/ViderumGlobal/ckan-cloud-provisioning-api)


## Install

Install Docker for [Windows](https://store.docker.com/editions/community/docker-ce-desktop-windows),
[Mac](https://store.docker.com/editions/community/docker-ce-desktop-mac) or [Linux](https://docs.docker.com/install/).

[Install Docker Compose](https://docs.docker.com/compose/install/)


## Running a CKAN instance using the docker-compose environment

(optional) Clear any existing compose environment to ensure a fresh start

```
docker-compose down -v
```

Pull the latest images

```
docker-compose pull
```

Start the Docker compose environment

```
docker-compose up -d ckan
```

Add a hosts entry mapping domain `nginx` to `127.0.0.1`:

```
127.0.0.1 nginx
```

Wait a few seconds until CKAN api responds successfully:

```
curl http://nginx:8080/api/3
```

Create a CKAN admin user

```
docker-compose exec ckan ckan-paster --plugin=ckan \
    sysadmin add -c /etc/ckan/production.ini admin password=12345678 email=admin@localhost
```

Login to CKAN at http://nginx:8080 with username `admin` and password `12345678`


## Making modifications to the docker images / configuration

Edit any file in this repository

(Optional) depending on the changes you made, you might need to destroy the current environment

```
docker-compose down -v
```

Build the docker images

```
docker-compose build | grep "Successfully tagged"
```

Start the environment

```
docker-compose up -d ckan
```


## Create a predefined docker-compose override configuration

This allows to test different CKAN configurations and extension combinations

Duplicate the CKAN default configuration:

```
cp docker-compose/ckan-conf-templates/production.ini.template \
   docker-compose/ckan-conf-templates/my-ckan-production.ini.template
```

Edit the duplicated file and modify the settings, e.g. add the extensions to the `plugins` configuration and any additional required extension configurations.

Create a docker-compose override file e.g. `.docker-compose.my-ckan.yaml`:

```
version: '3.2'

services:
  jobs:
    build:
      context: ckan
      args:
        # install extensions / dependencies
        POST_INSTALL: |
          install_standard_ckan_extension_github ckan/ckanext-spatial ckanext-spatial &&\
          install_standard_ckan_extension_github ckan/ckanext-harvest ckanext-harvest &&\
          install_standard_ckan_extension_github GSA/ckanext-geodatagov ckanext-geodatagov &&\
          install_standard_ckan_extension_github GSA/ckanext-datagovtheme ckanext-datagovtheme
        # other initialization
        POST_DOCKER_BUILD: |
          mkdir -p /var/tmp/ckan/dynamic_menu
    environment:
    # used to load the modified CKAN configuration
    - CKAN_CONFIG_TEMPLATE_PREFIX=my-ckan-
  ckan:
    build:
      context: ckan
      args:
        # install extensions / dependencies
        POST_INSTALL: |
          install_standard_ckan_extension_github ckan/ckanext-spatial ckanext-spatial &&\
          install_standard_ckan_extension_github ckan/ckanext-harvest ckanext-harvest &&\
          install_standard_ckan_extension_github GSA/ckanext-geodatagov ckanext-geodatagov &&\
          install_standard_ckan_extension_github GSA/ckanext-datagovtheme ckanext-datagovtheme
        # other initialization
        POST_DOCKER_BUILD: |
          mkdir -p /var/tmp/ckan/dynamic_menu
    environment:
    # used to load the modified CKAN configuration
    - CKAN_CONFIG_TEMPLATE_PREFIX=my-ckan-
```

Start the docker-compose environment with the modified config:

```
docker-compose -f docker-compose.yaml -f .docker-compose.my-ckan.yaml up -d --build ckan
```

You can persist the modified configurations in Git for reference and documentation.

For example, to start the datagov-theme configuration:

```
docker-compose -f docker-compose.yaml -f .docker-compose.datagov-theme.yaml up -d --build ckan
```

## Running cca-operator

see [cca-operator README](cca-operator/README.md)


## Run the Jenkins server

```
docker-compose up -d jenkins
```

Login at http://localhost:8089


## Running the cloud provisioning API

Start the cca-operator server (see [cca-operator README](cca-operator/README.md))

Start the cloud provisioning API server with the required keys

```
export PRIVATE_SSH_KEY="$(cat docker-compose/cca-operator/id_rsa | while read i; do echo "${i}"; done)"
export PRIVATE_KEY="$(cat docker-compose/provisioning-api/private.pem | while read i; do echo "${i}"; done)"
export PUBLIC_KEY="$(cat docker-compose/provisioning-api/public.pem | while read i; do echo "${i}"; done)"

docker-compose up -d --build provisioning-api
```


## Using a centralized DB

Set the following env vars for cca-operator ckan init scripts:

```
CKAN_CLOUD_POSTGRES_HOST=
CKAN_CLOUD_INSTANCE_ID=
PGPASSWORD=
```

cca-operator's initialize-ckan-env-vars command will create the DB for the instance

To test CKAN locally - create a modified ckan/ckan-secrets.sh file with the connection details to the specific instance's DB

Override the relevant volume in docker-compose.override.yaml
