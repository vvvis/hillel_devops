#!/bin/bash

DB_NAME=$(cat ./config.json | jq -r '.db.name')
DB_USERNAME=$(cat ./config.json | jq -r '.db.username') 
DB_PASSWORD=$(cat ./config.json | jq -r '.db.password')
SITENAME=$(cat ./config.json | jq -r '.sitename')
SITEROOT=$(cat ./config.json | jq -r '.siteroot_dir')
BACKUP_PERIOD=$(cat ./config.json | jq -r '.backup.period')

#Verivy script is running from root
if [[ `whoami` != "root" ]]; 
    then
        logger -s "Deployment script must be started from root! Elevate privilleges and restart the scrip."
        exit 1
fi

#INSTALLATION OF REQUIRED LAMP INFRASTRUCTURE
apt update
if [ $(dpkg-query -W -f='${Status}'  apache2 >/dev/null | grep -c "ok installed") -eq 0 ];
    then
        apt-get install apache2;
fi

if [ $(dpkg-query -W -f='${Status}' default-mysql-server | grep -c "ok installed") -eq 0 ];
    then
        apt-get install default-mysql-server;
fi

if [ $(dpkg-query -W -f='${Status}' php | grep -c "ok installed") -eq 0 ];
    then
        apt-get install php;
fi

if [ $(dpkg-query -W -f='${Status}' php7.3-mysq | grep -c "ok installed") -eq 0 ];
    then
        apt-get install php7.3-mysq;
fi

#Download and unpack wordpress
wget https://uk.wordpress.org/latest-uk.tar.gz
tar xzvf latest-uk.tar.gz -C $SITEROOT
mv $SITEROOT/wordpress/* $SITEROOT
rmdir $SITEROOT/wordpress/
rm $SITEROOT/index.html

#Verify ports for apache
if [ $(lsof -i:22 | grep -c "LISTEN") -ne 0 ];
    then
        logger -s "Port 80 is occupied by another application. Resolve the issue and restart the script."
	exit 1
    else
        echo "<VirtualHost *:80>
	ServerName \"${SITENAME}\"
	ServerAdmin webmaster@${SITENAME}
	DocumentRoot ${SITEROOT}
	ErrorLog \${APACHE_LOG_DIR}/${PROJECT}-error.log
	CustomLog \${APACHE_LOG_DIR}/${PROJECT}-access.log combined
</VirtualHost>" > /etc/apache2/sites-enabled/001-wordpress.conf
fi

#Start or restart apache service depending on its status
if [ $(systemctl status apache2 | grep -c "Active: active") -eq 1];
    then
        systemctl restart apache2
    else
        systemctl start apache2
fi

systemctl start mysqld
mysql -e "CREATE DATABASE \`${DB_NAME};"
mysql -e "CREATE USER '${DB_USERNMAME}' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -e "GRANT USAGE ON *.* TO '${DB_USERNAME}'@localhost IDENTIFIED BY '${DB_PASSWORD}';"
mysql -e "GRANT ALL privileges ON \`${DB_NAME}\`.* TO '${DB_USERNAME}'@localhost;"
mysql -e "FLUSH PRIVILEGES;"

#CREATE BACKUP SCRIPT
echo "
#!/bin/bash

DB_NAME=\$(cat ~/config.json | jq -r '.db.name')
DB_USERNAME=\$(cat ~/config.json | jq -r '.db.username') 
DB_PASSWORD=\$(cat ~/config.json | jq -r '.db.password')
BACKUP_DIR=\$(cat ~/config.json | jq -r '.backup.dir')
BACKUP_COUNT=\$(cat ~/config.json | jq -r '.backup.count')
SITEROOT=\$(cat ~/config.json | jq -r '.siteroot_dir')

#Init backup folder structure and remove obsolete backups
PERIODIC_BACKUP_DIR=\"backup-\`date +%b.%d.%y-%H:%M:%S\`\"
mkdir \$BACKUP_DIR 
mkdir \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR

#Apache config backup + LOGS
mkdir \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR/apache
mkdir \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR/logs
cp /etc/apache2/apache2.conf \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR/apache
cp -R /etc/apache2/sites-enabled/ \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR/apache/sites-enabled/
cp -R /etc/apache2/sites-available/ \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR/apache/sites-available/
cp -R /var/log/apache2/ \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR/apache/logs/

#webroot backup
mkdir \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR/Webroot
cp -R \$SITEROOT \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR/Webroot/

#MySQL Backup
mkdir \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR/MySQL
mkdir \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR/MySQL/Databases
cp /etc/mysql/my.cnf \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR/MySQL
mysqldump --user \$DB_USERNAME --password=\$DB_PASSWORD --all-databases > \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR/MySQL/Databases/_all.sql

mysql --user \$DB_USERNAME --password=\$DB_PASSWORD -e \"show databases;\" -s | awk '{ if (NR > 2 ) {print } }' |
while IFS= read -r database; do
    mysqldump --user \$DB_USERNAME --password=\$DB_PASSWORD \"\$database\" > \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR/MySQL/Databases/\$database.sql
done

#Archiving & cleanup
tar -zcvf \$BACKUP_DIR/Backup_\$PERIODIC_BACKUP_DIR.tar.gz \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR && rm -rf \$BACKUP_DIR/\$PERIODIC_BACKUP_DIR
cd \$BACKUP_DIR && ls -t | sed -e \"1,\${BACKUP_COUNT}d\" | xargs -d '\n' rm -rf" > /usr/local/bin/batch.sh

chmod +x /usr/local/bin/batch.sh

#setup required backup procedure period
crontab -l | { cat; echo "$BACKUP_PERIOD /usr/local/bin/batch.sh"; } | crontab -


