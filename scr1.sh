#!/bin/bash

# Функція для перевірки успішності виконання команд
check_success() {
    if [ $? -ne 0 ]; then
        echo "Помилка: $1"
        exit 1
    fi
}

# Встановлення змінних для уникнення інтерактивних запитів
export DEBIAN_FRONTEND=noninteractive

# Генерація паролів
root_password=$(openssl rand -base64 12)
phpmyadmin_password=$(openssl rand -base64 12)
app_password=$(openssl rand -base64 12)

# Створення файлу для автоматичного налаштування phpMyAdmin
debconf-set-selections <<EOF
phpmyadmin phpmyadmin/dbconfig-install boolean true
phpmyadmin phpmyadmin/app-password-confirm password $app_password
phpmyadmin phpmyadmin/mysql/admin-pass password $root_password
phpmyadmin phpmyadmin/mysql/app-pass password $app_password
phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2
EOF

# Оновлення системи
echo "Оновлюємо систему..."
apt update && apt upgrade -y
check_success "Не вдалося оновити систему"

# Встановлення Apache
echo "Встановлюємо Apache..."
apt install -y apache2
check_success "Не вдалося встановити Apache"

# Встановлення MariaDB без запитів пароля
echo "Встановлюємо MariaDB..."
apt install -y mariadb-server mariadb-client
check_success "Не вдалося встановити MariaDB"

# Запуск і налаштування MariaDB
echo "Налаштовуємо MariaDB..."
systemctl start mariadb
systemctl enable mariadb

# Очікування запуску MariaDB
sleep 5

# Налаштування root пароля та безпеки MariaDB
mysql -u root <<EOF
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${root_password}');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
check_success "Не вдалося налаштувати MariaDB"

# Встановлення PHP та phpMyAdmin без інтерактивних запитів
echo "Встановлюємо PHP та phpMyAdmin..."
apt install -y php php-mbstring php-zip php-gd php-json php-curl
apt install -y phpmyadmin
check_success "Не вдалося встановити PHP та phpMyAdmin"

# Налаштування phpMyAdmin з Apache
echo "Налаштовуємо phpMyAdmin з Apache..."
ln -sf /usr/share/phpmyadmin /var/www/html/phpmyadmin
check_success "Не вдалося налаштувати символічне посилання для phpMyAdmin"

# Створення конфігурації Apache для phpMyAdmin
echo 'Alias /phpmyadmin /usr/share/phpmyadmin' > /etc/apache2/conf-available/phpmyadmin.conf
a2enconf phpmyadmin
systemctl reload apache2
check_success "Не вдалося налаштувати Apache для phpMyAdmin"

# Створення користувача phpMyAdmin
echo "Створюємо користувача для phpMyAdmin..."
mysql -u root -p"${root_password}" <<EOF
CREATE USER IF NOT EXISTS 'admin'@'localhost' IDENTIFIED BY '${phpmyadmin_password}';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
check_success "Не вдалося створити користувача phpMyAdmin"

# Кольоровий вивід результатів
GREEN="\033[0;32m"
BLUE="\033[0;34m"
RESET="\033[0m"

echo -e "${GREEN}Встановлення завершено успішно!${RESET}"
echo -e "${BLUE}Логін (phpMyAdmin):${RESET} admin"
echo -e "${BLUE}Пароль (phpMyAdmin):${RESET} ${GREEN}$phpmyadmin_password${RESET}"
echo -e "${BLUE}Пароль root (MariaDB):${RESET} ${GREEN}$root_password${RESET}"
echo -e "${BLUE}Адреса phpMyAdmin:${RESET} http://$(hostname -I | awk '{print $1}')/phpmyadmin"
