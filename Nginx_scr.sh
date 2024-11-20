#!/bin/bash

# Встановлення змінних оточення для неінтерактивного режиму
export DEBIAN_FRONTEND=noninteractive

# Генерація випадкового пароля для MariaDB та phpMyAdmin
DB_ROOT_PASSWORD=$(openssl rand -base64 12)
PHPMYADMIN_PASS=$(openssl rand -base64 12)

# Попереднє налаштування phpmyadmin
echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
echo "phpmyadmin phpmyadmin/app-password-confirm password $PHPMYADMIN_PASS" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/admin-pass password $DB_ROOT_PASSWORD" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/app-pass password $PHPMYADMIN_PASS" | debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect none" | debconf-set-selections

# Оновлення пакетів
apt update && apt upgrade -y

# Встановлення необхідних пакетів
apt install nginx mariadb-server mariadb-client php-fpm php-mysql php-mbstring php-xml php-gd php-curl php-zip php-json php-bz2 -y

# Налаштування root пароля MariaDB
mysqladmin -u root password "$DB_ROOT_PASSWORD"

# Налаштування безпеки MariaDB
mysql -u root -p"$DB_ROOT_PASSWORD" <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

# Створення бази даних та користувача для phpMyAdmin
mysql -u root -p"$DB_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS phpmyadmin DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'phpmyadmin'@'localhost' IDENTIFIED BY '$PHPMYADMIN_PASS';
GRANT ALL PRIVILEGES ON phpmyadmin.* TO 'phpmyadmin'@'localhost';
FLUSH PRIVILEGES;
EOF

# Встановлення phpMyAdmin
apt install phpmyadmin -y

# Створення та налаштування конфігураційного файлу phpMyAdmin
cat > /etc/phpmyadmin/config.inc.php <<EOF
<?php
\$cfg['blowfish_secret'] = '$(openssl rand -base64 32)';
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['connect_type'] = 'tcp';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['Servers'][\$i]['user'] = 'phpmyadmin';
\$cfg['Servers'][\$i]['password'] = '$PHPMYADMIN_PASS';
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
\$cfg['TempDir'] = '/tmp';
?>
EOF

# Налаштування прав доступу
chown -R www-data:www-data /etc/phpmyadmin
chmod 755 /etc/phpmyadmin
chmod 644 /etc/phpmyadmin/config.inc.php

# Створення символічного посилання
ln -sf /usr/share/phpmyadmin /var/www/html/

# Налаштування Nginx
cat > /etc/nginx/conf.d/phpmyadmin.conf <<EOF
server {
    listen 80;
    server_name _;
    root /var/www/html/phpmyadmin;
    index index.php index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/var/run/php/php$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }
    
    location ~ /\.ht {
        deny all;
    }
}
EOF

# Видалення стандартної конфігурації
rm -f /etc/nginx/sites-enabled/default

# Перезапуск сервісів
systemctl restart nginx
systemctl restart php$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")-fpm
systemctl restart mysql

# Імпорт схеми бази даних phpMyAdmin
zcat /usr/share/doc/phpmyadmin/examples/create_tables.sql.gz | mysql -u phpmyadmin -p"$PHPMYADMIN_PASS" phpmyadmin

# Виведення інформації
echo "Встановлення завершено"
echo "Пароль root для MariaDB: $DB_ROOT_PASSWORD"
echo "Пароль користувача phpmyadmin: $PHPMYADMIN_PASS"
echo "phpMyAdmin доступний за адресою http://$(hostname -I | awk '{print $1}')/phpmyadmin"
