#!/bin/bash

# This script is to be executed ONCE from a Digital Ocean droplet since the database connection is restricted to their associated server

DROPLET_HOSTNAME=$(curl -s http://169.254.169.254/metadata/v1/hostname)
DROPLET_TAGS=$(curl -s http://169.254.169.254/metadata/v1/tags/ | paste -sd ', ')

HASURA_VERSION="latest"
DOKKU_APP=""
ROOT_DATABASE_URL=""
HASURAUSER_DATABASE_URL=""
LETSENCRYPT_EMAIL="william.hollacsek@gmail.com"

echo "Setting up Hasura on ${DROPLET_HOSTNAME} (${DROPLET_TAGS})"
read -p "Dokku app name: " -i "graphql-engine" -e DOKKU_APP
read -p "Root database url: " -i "postgresql://doadmin:REDACTED@REDACTED.db.ondigitalocean.com:25060/defaultdb?sslmode=require" -e ROOT_DATABASE_URL
if echo "${ROOT_DATABASE_URL}" | grep -q "REDACTED"; then
    echo "Please replace REDACTED with appropriate values!"
    exit 1
fi

echo "You are about to deploy Hasura as a Dokku app (${DOKKU_APP}) using the database (${ROOT_DATABASE_URL})"
read -p "Confirm? (N/y) " -i "N" -e CONFIRMED
if [[ "${CONFIRMED,,}" != "y" ]]; then
    exit 1
fi

if dokku apps:exists "$DOKKU_APP" 2> /dev/null; then
    echo "Please delete the existing ${DOKKU_APP} app!"
    exit 1
fi

HASURAUSER_DATABASE_URL=$(echo "${ROOT_DATABASE_URL}" | sed -e 's \(//\).*@ \1hasurauser:hasurauser@ ')
IS_PRODUCTION=$(echo "${DROPLET_TAGS}" | grep -iq Production; echo $?)
DOKKU_APP_DOMAIN=$([[ ${IS_PRODUCTION} -eq 0 ]] && echo "prod" || echo "dev")-$DOKKU_APP.athleads.com
HASURA_GRAPHQL_ADMIN_SECRET=$(openssl rand -hex 24)
HASURA_GRAPHQL_CORS_DOMAIN="https://athleads.com"

# Install psql on server
# see: https://pgdash.io/blog/postgres-11-getting-started.html
if  ! hash psql; then
    sudo tee /etc/apt/sources.list.d/pgdg.list <<END
deb http://apt.postgresql.org/pub/repos/apt/ bionic-pgdg main
END
    wget https://www.postgresql.org/media/keys/ACCC4CF8.asc
    sudo apt-key add ACCC4CF8.asc
    sudo apt-get update
    sudo apt install postgresql-client-12
fi

# Create postgres user
# see: https://hasura.io/docs/1.0/graphql/manual/deployment/postgres-requirements.html#postgres-permissions
tee /tmp/setup_hasurauser.sql 1> /dev/null <<EOF
-- We will create a separate user and grant permissions on hasura-specific
-- schemas and information_schema and pg_catalog
-- These permissions/grants are required for Hasura to work properly.

-- create a separate user for hasura
CREATE USER hasurauser WITH PASSWORD 'hasurauser';

-- create pgcrypto extension, required for UUID
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- create the schemas required by the hasura system
-- NOTE: If you are starting from scratch: drop the below schemas first, if they exist.
CREATE SCHEMA IF NOT EXISTS hdb_catalog;
CREATE SCHEMA IF NOT EXISTS hdb_views;

-- make the user an owner of system schemas
GRANT hasurauser to doadmin;
ALTER SCHEMA hdb_catalog OWNER TO hasurauser;
ALTER SCHEMA hdb_views OWNER TO hasurauser;

-- grant select permissions on information_schema and pg_catalog. This is
-- required for hasura to query the list of available tables.
-- NOTE: these permissions are usually available by default to all users via PUBLIC grant
GRANT SELECT ON ALL TABLES IN SCHEMA information_schema TO hasurauser;
GRANT SELECT ON ALL TABLES IN SCHEMA pg_catalog TO hasurauser;

-- The below permissions are optional. This is dependent on what access to your
-- tables/schemas you want give to hasura. If you want expose the public
-- schema for GraphQL query then give permissions on public schema to the
-- hasura user.
-- Be careful to use these in your production db. Consult the postgres manual or
-- your DBA and give appropriate permissions.

-- grant all privileges on all tables in the public schema. This can be customised:
-- For example, if you only want to use GraphQL regular queries and not mutations,
-- then you can set: GRANT SELECT ON ALL TABLES...
GRANT USAGE ON SCHEMA public TO hasurauser;
GRANT ALL ON ALL TABLES IN SCHEMA public TO hasurauser;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO hasurauser;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO hasurauser;

-- Similarly add these for other schemas as well, if you have any.
-- GRANT USAGE ON SCHEMA <schema-name> TO hasurauser;
-- GRANT ALL ON ALL TABLES IN SCHEMA <schema-name> TO hasurauser;
-- GRANT ALL ON ALL SEQUENCES IN SCHEMA <schema-name> TO hasurauser;
-- GRANT ALL ON ALL FUNCTIONS IN SCHEMA <schema-name> TO hasurauser;
EOF

psql "${ROOT_DATABASE_URL}" -f /tmp/setup_hasurauser.sql

# Create the dokku app
dokku apps:create "$DOKKU_APP"

# Update port forwarding
dokku proxy:ports-set "$DOKKU_APP" http:80:8080

# Setup domain
dokku domains:add "$DOKKU_APP" "$DOKKU_APP_DOMAIN"

# Update the docker options for the deploy phase to inject database credentials
# see: http://dokku.viewdocs.io/dokku/deployment/methods/dockerfiles/#build-time-configuration-variables
# see: https://hasura.io/docs/1.0/graphql/manual/deployment/deployment-guides/docker.html#deployment-docker
dokku docker-options:add "$DOKKU_APP" deploy "-e HASURA_GRAPHQL_DATABASE_URL=${HASURAUSER_DATABASE_URL} -e HASURA_GRAPHQL_ADMIN_SECRET=${HASURA_GRAPHQL_ADMIN_SECRET}"

if [[ $IS_PRODUCTION -eq 0 ]]
then
    dokku docker-options:add "$DOKKU_APP" deploy "-e HASURA_GRAPHQL_ENABLED_APIS=graphql -e HASURA_GRAPHQL_CORS_DOMAIN=${HASURA_GRAPHQL_CORS_DOMAIN}"
else
    dokku docker-options:add "$DOKKU_APP" deploy '-e HASURA_GRAPHQL_ENABLE_CONSOLE=true'
fi

# Fetch hasura docker image
sudo docker pull hasura/graphql-engine:$HASURA_VERSION

# Retag the image with the dokku app name
sudo docker tag hasura/graphql-engine:$HASURA_VERSION dokku/"$DOKKU_APP":$HASURA_VERSION

# Deploy the renamed image
dokku tags:deploy "$DOKKU_APP" $HASURA_VERSION

# Enable Letsencrypt
dokku config:set --no-restart "$DOKKU_APP" DOKKU_LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
dokku letsencrypt "$DOKKU_APP"

echo "----------8<----------"
echo "Please save the generated Hasura admin secret:"
echo ${HASURA_GRAPHQL_ADMIN_SECRET}
echo "----------8<----------"
