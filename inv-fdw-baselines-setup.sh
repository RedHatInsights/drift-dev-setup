#!/usr/bin/env sh

# read connection details and credentials from host-inventory secret
INV_DB_HOST=$(oc get secret host-inventory -o yaml | yq '.data."cdappconfig.json"' | base64 --decode | jq --raw-output .database.hostname)
INV_DB_PORT=$(oc get secret host-inventory -o yaml | yq '.data."cdappconfig.json"' | base64 --decode | jq --raw-output .database.port)
INV_DB_NAME=$(oc get secret host-inventory -o yaml | yq '.data."cdappconfig.json"' | base64 --decode | jq --raw-output .database.name)
INV_DB_PASS=$(oc get secret host-inventory -o yaml | yq '.data."cdappconfig.json"' | base64 --decode | jq --raw-output .database.password)
INV_DB_USER=$(oc get secret host-inventory -o yaml | yq '.data."cdappconfig.json"' | base64 --decode | jq --raw-output .database.username)



BASELINE_DB_ADMIN_USER=$(oc rsh $(oc get pods --output name | grep baseline-backend | head -n1) cat /cdapp/cdappconfig.json | jq --raw-output .database.adminUsername)
BASELINE_DB_ADMIN_PASS=$(oc rsh $(oc get pods --output name | grep baseline-backend | head -n1) cat /cdapp/cdappconfig.json | jq --raw-output .database.adminPassword)
BASELINE_DB_NAME=$(oc rsh $(oc get pods --output name | grep baseline-backend | head -n1) cat /cdapp/cdappconfig.json | jq --raw-output .database.name)
BASELINE_DB_HOST=$(oc rsh $(oc get pods --output name | grep baseline-backend | head -n1) cat /cdapp/cdappconfig.json | jq --raw-output .database.hostname)
BASELINE_DB_PORT=$(oc rsh $(oc get pods --output name | grep baseline-backend | head -n1) cat /cdapp/cdappconfig.json | jq --raw-output .database.port)
BASELINE_DB_USER=$(oc rsh $(oc get pods --output name | grep baseline-backend | head -n1) cat /cdapp/cdappconfig.json | jq --raw-output .database.username)
BASELINE_DB_PASS=$(oc rsh $(oc get pods --output name | grep baseline-backend | head -n1) cat /cdapp/cdappconfig.json | jq --raw-output .database.password)

echo $INV_DB_HOST
echo $INV_DB_PORT
echo $INV_DB_NAME
echo $INV_DB_USER
echo $INV_DB_PASS

echo $BASELINE_DB_USER

pgrep oc -a | grep port-forward | grep system-baseline-db | awk '{print $1}' | xargs -n1 kill 
echo oc port-forward $(oc get service --output name | grep system-baseline-db) "10001:$BASELINE_DB_PORT"
oc port-forward $(oc get service --output name | grep system-baseline-db) "10001:$BASELINE_DB_PORT" > /dev/null 2>&1 &

pgrep oc -a | grep port-forward | grep host-inventory-db | awk '{print $1}' | xargs -n1 kill 
echo oc port-forward $(oc get service --output name | grep host-inventory-db) "10002:$INV_DB_PORT"
oc port-forward $(oc get service --output name | grep host-inventory-db) "10002:$INV_DB_PORT" > /dev/null 2>&1 &

sleep 5

remote_admin_sql() {
    db_url="postgresql://$BASELINE_DB_ADMIN_USER:$BASELINE_DB_ADMIN_PASS@localhost:10001/$BASELINE_DB_NAME"
    echo '---'
    echo "ADMIN"
    # echo "$db_url"
    # echo "$1"
    # oc rsh $(oc get pods --output name | grep baseline-backend | head -n1) psql "$db_url" --command "$1"
    which psql
    echo psql "$db_url" --command "$1"
    psql "$db_url" --command "$1"
    echo '---'
}

remote_user_sql() {
     db_url="postgresql://$BASELINE_DB_USER:$BASELINE_DB_PASS@localhost:10001/$BASELINE_DB_NAME"
     echo '---'
     echo "USER"
     # echo "$db_url"
     # echo "$1"
     # oc rsh $(oc get pods --output name | grep baseline-backend | head -n1) psql "$db_url" --command "$1"
     which psql
     echo psql "$db_url" --command "$1"
     psql "$db_url" --command "$1"
     echo '---'
}

remote_inv_sql() {
    db_url="postgresql://$INV_DB_USER:$INV_DB_PASS@localhost:10002/$INV_DB_NAME"
    echo '---'
    echo "INV"
    # echo "$db_url"
    # echo "$1"
    # oc rsh $(oc get pods --output name | grep baseline-backend | head -n1) psql "$db_url" --command "$1"
    which psql
    echo psql "$db_url" --command "$1"
    psql "$db_url" --command "$1"
    echo '---'
}

# list tables in inventory db
remote_inv_sql "SELECT * FROM pg_catalog.pg_tables WHERE schemaname != 'pg_catalog' AND schemaname != 'information_schema';"

# list tables in baselines db
remote_user_sql "SELECT * FROM pg_catalog.pg_tables WHERE schemaname != 'pg_catalog' AND schemaname != 'information_schema';"

# list postgres extensions, create fdw one, list them again to confirm, list foreign data wrappers
remote_admin_sql "SELECT * FROM pg_extension;"
remote_admin_sql "CREATE EXTENSION IF NOT EXISTS postgres_fdw;"
remote_admin_sql "SELECT * FROM pg_extension;"
remote_admin_sql "SELECT fdwname FROM pg_foreign_data_wrapper;"

# list foreign servers, drop if exists, list again, create foreign data wrapper with connection options, list again
remote_admin_sql "SELECT * FROM pg_foreign_server;"
remote_admin_sql "DROP SERVER IF EXISTS host_inventory_fdw CASCADE;"
remote_admin_sql "SELECT * FROM pg_foreign_server;"
remote_admin_sql "CREATE SERVER host_inventory_fdw FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host '"$INV_DB_HOST"', port '"$INV_DB_PORT"', dbname '"$INV_DB_NAME"');"
remote_admin_sql "SELECT * FROM pg_foreign_server;"

# create proper user mapping - so local baselines can access remote data using remote user
remote_admin_sql "SELECT * FROM pg_user_mapping;"
remote_admin_sql "CREATE USER MAPPING FOR \"$BASELINE_DB_USER\" SERVER host_inventory_fdw OPTIONS (user '"$INV_DB_USER"', password '"$INV_DB_PASS"');"
remote_admin_sql "SELECT * FROM pg_user_mapping;"

# grant usage to local user on foreign data wrapper
remote_admin_sql "GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO \"$BASELINE_DB_USER\";"

# list local foreign tables, import public schema from fdw'ed db (hosts table only) into local public schema, list again
remote_user_sql "SELECT * from information_schema.foreign_tables;"
remote_user_sql "IMPORT FOREIGN SCHEMA public LIMIT TO (hosts) FROM SERVER host_inventory_fdw INTO public;"
remote_user_sql "SELECT * from information_schema.foreign_tables;"

# do a query on both original db and local one
remote_inv_sql "SELECT count(*) from hosts;"
remote_user_sql "SELECT count(*) from hosts;"
