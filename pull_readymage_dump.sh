#!/bin/bash

# Hint: example of using option/argument inside -- switch case:
#  val="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
#  echo "Parsing option: '--${OPTARG}', value: '${val}'" >&2;

# TODO: Clone core_config_data from old database
# TODO: Sanitization
# TODO: --dest seems to be not working when runnin from different from flag destination

set -Eeuo pipefail

no_import=false
ssh=null
db_name=null
dest='.'
keep_dump=false
show_output=false
existing_db_name=null

# Color variables
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
magenta='\033[0;35m'
cyan='\033[0;36m'
clear='\033[0m'

optspec=":-:"
while getopts "$optspec" optchar; do
    case "${optchar}" in
        -)
            case "${OPTARG}" in
                show-output)
					show_output=true
                    ;;
                no-reply)
					no_import=true
                    ;;
                ssh=*)
                    val=${OPTARG#*=}
					ssh=$val
                    ;;
                db-name=*)
                    val=${OPTARG#*=}
					db_name=$val
                    ;;
				dest=*)
                    val=${OPTARG#*=}
					dest=$val
                    ;;
				keep-dump=*)
                    keep_dump=true
                    ;;
                existing-db-name=*)
                    val=${OPTARG#*=}
					existing_db_name=$val

                    ;;
				help*)
                    echo "\n"
                    printf -- "${yellow}Usage: \n"
                    printf -- "    ${clear}$0 [option...] [argument...]"

                    echo "\n\n"

                    printf -- "${yellow}Options: \n"
                    printf -- "    ${green}--help                ${yellow}Display this help message \n"
                    printf -- "    ${green}--show-output         ${yellow}Show output of each step \n"
                    printf -- "    ${green}--ssh                 ${yellow}SSH server credentials ${clear}(e.g. ${magenta}user@readymage.com ${clear}or can use aliasfrom ${magenta}~/.ssh/config${clear}) \n"
                    printf -- "    ${green}--db-name             ${yellow}Database name to use for local import \n"
                    printf -- "    ${green}--existing-db-name    ${yellow}Existing database name to export configuration \n"
                    printf -- "    ${green}--dest                ${yellow}Destination for SCP command ${clear}(Default value is current folder) \n"
                    printf -- "    ${green}--keep-dump           ${yellow}Either keep dump after importing or delete it ${clear}(${magenta}false ${clear}by default) \n"

                    echo "\n"
                    exit 1
                    ;;
                *)
                    if [ "$OPTERR" = 1 ] && [ "${optspec:0:1}" != ":" ]; then
                        echo "Unknown option --${OPTARG}" >&2
                    fi
                    ;;
            esac;;
        *)
            if [ "$OPTERR" != 1 ] || [ "${optspec:0:1}" = ":" ]; then
                echo "Non-option argument: '-${OPTARG}'" >&2
            fi
            ;;
    esac
done

if [ $ssh = null ]; then
	printf -- "⛔️ ${red}Please provide SSH server (${yellow}--ssh${red})\n"
	exit
fi

if ! ssh -q $ssh "true"; then
    printf -- "⛔️ ${red}Unable to connect to ${cyan}${ssh}\n"
	exit
fi

if [ $db_name = null ]; then
	printf -- "⛔️ ${red}Please provide database name (${yellow}--db-name${red})\n"
	exit
fi

if [ $show_output = true ]; then
    set -x
fi

printf -- "⏱  ${yellow}Creating dump on '${cyan}${ssh}${yellow}' server... \n"

ssh -q $ssh 'mysqldump magento --single-transaction --no-tablespaces | zip dump.sql.gz -' > /dev/null

printf -- "✅ ${green}Creating dump \n"

printf -- "\n⏱  ${yellow}Pulling dump... \n"

if [ $show_output = true ]; then
    scp ${ssh}:./dump.sql.gz $dest;
else
    scp -q ${ssh}:./dump.sql.gz $dest;
fi

printf -- "✅ ${green}Pulling dump... \n"

printf -- "\n⏱  ${yellow}Unzipping dump... \n"

tar -xf ${dest}/dump.sql.gz
mv - dump.sql

printf -- "✅ ${green}Unzipping dump... \n"

if [ $no_import = true ]; then
	printf -- "🟡 ${yellow}Import is disabled \n"
else
	if mysqlshow 2>/dev/null | grep -q $db_name; then
		while true; do
			printf -- "${cyan} \n"; read -p "🟡 Database already exist. Do you want to rewrite it? (y/n) " yn
			case $yn in
			[Yy]*)
				printf -- "\n⏱  ${yellow}Deleting old database... \n"

				mysql -e "DROP DATABASE \`$db_name\`;"

				printf -- "✅ ${green}Deleting old database... \n"
				break
				;;
			[Nn]*) exit ;;
			*) printf -- "${red}Please answer yes or no. ${blue} \n" ;;
			esac
		done
	fi

	printf -- "\n⏱  ${yellow}Applying dump... \n"

	mysql -e "CREATE DATABASE \`$db_name\`;"
	mysql "$db_name" < ${dest}/dump.sql

	printf -- "✅ ${green}Applying dump... \n"

	if [ $keep_dump = false ]; then
		printf -- "\n ⏱  ${yellow}Deleting dump... \n"

		rm -rf ${dest}/dump.sql

		printf -- "✅ ${green}Deleting dump... \n"
	fi

    if [ ! $existing_db_name = null ];then
        printf -- "\n⏱  ${yellow}Importing old configuration... \n"

        if mysqlshow 2>/dev/null | grep -q $existing_db_name; then
            # do dump
            # mysql --database puma-uae-ksa4 --execute='Select path, value from core_config_data where path like "%url%";' -X > ~/Downloads/file.xml
            # mysql use puma-uae-ksa-4; TO LOAD
            # LOAD XML LOCAL INFILE '~/Downloads/file.xml' INTO TABLE core_config_data(path,value);

            # https://stackoverflow.com/questions/15271202/mysql-load-data-infile-with-on-duplicate-key-update
            # Create a new temporary table.

            # CREATE TEMPORARY TABLE temporary_table LIKE target_table ;
            # ORRR
            # CREATE TEMPORARY TABLE temporary_table SELECT * FROM target_table WHERE 1=0; TO COMBINE NEXT STEP
            # Optionally, drop all indices from the temporary table to speed things up.

            # SHOW INDEX FROM temporary_table;
            # DROP INDEX `PRIMARY` ON temporary_table;
            # DROP INDEX `some_other_index` ON temporary_table;
            # Load the CSV into the temporary table

            # LOAD DATA INFILE 'your_file.csv'
            # INTO TABLE temporary_table
            # FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
            # (field1, field2);
            # Copy the data using ON DUPLICATE KEY UPDATE

            # SHOW COLUMNS FROM target_table;
            # INSERT INTO target_table
            # SELECT * FROM temporary_table
            # ON DUPLICATE KEY UPDATE field1 = VALUES(field1), field2 = VALUES(field2);
            # Remove the temporary table

            # DROP TEMPORARY TABLE temporary_table;
            # Using SHOW INDEX FROM and SHOW COLUMNS FROM this process can be automated for any given table.


            echo "TIPO DELAEM IMPORT";
        else
            printf -- "🟡 ${yellow}Database $existing_db_name does not exist, skipping \n"
        fi
    fi
fi

printf -- "\n✅✅✅ ${green}Done \n\n"
