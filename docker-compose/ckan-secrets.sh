export BEAKER_SESSION_SECRET=d81d3c0095114bde9ce04e66e32e2f5dd97ec81ce377636183
export APP_INSTANCE_UUID=df93ee4a-da20-11e8-8c76-e4a4719186ba
export SQLALCHEMY_URL=postgresql://ckan:123456@db/ckan
export CKAN_DATASTORE_WRITE_URL=postgresql://postgres:123456@datastore-db/datastore
export CKAN_DATASTORE_READ_URL=postgresql://readonly:123456@datastore-db/datastore
export SOLR_URL=http://solr:8983/solr/ckan
export CKAN_REDIS_URL=redis://redis:6379/1
export CKAN_DATAPUSHER_URL=http://datapusher:8800/
export AWS_ACCESS_KEY_ID=
export AWS_SECRET_ACCESS_KEY=
export SMTP_SERVER=
export SMTP_USER=
export SMTP_PASSWORD=
export CKAN_SITE_URL=
export SENTRY_DSN=

[[ -f "./ckan-secrets-local.sh" ]] && source "./ckan-secrets-local.sh"
