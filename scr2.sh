#!/bin/bash

# Перевірка прав root
if [[ $EUID -ne 0 ]]; then
   echo "Цей скрипт повинен запускатися з правами root"
   exit 1
fi

# Налаштування кольорів для виводу
readonly RED="\033[0;31m"
readonly GREEN="\033[0;32m"
readonly YELLOW="\033[1;33m"
readonly BLUE="\033[0;34m"
readonly RESET="\033[0m"

# Налаштування логування
readonly LOG_FILE="/var/log/lamp-install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

# Функція для виводу повідомлень
log() {
    local type=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case $type in
        "INFO") echo -e "${BLUE}[INFO]${RESET} ${timestamp} - $message" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${RESET} ${timestamp} - $message" ;;
        "ERROR") echo -e "${RED}[ERROR]${RESET} ${timestamp} - $message" ;;
        "WARNING") echo -e "${YELLOW}[WARNING]${RESET} ${timestamp} - $message" ;;
    esac
}

# Функція для перевірки успішності виконання команд
check_success() {
    if [ $? -ne 0 ]; then
        log "ERROR" "$1"
        exit 1
    fi
}

# Функція для перевірки доступності порту
check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null ; then
        log "WARNING" "Порт $port вже використовується"
        return 1
    fi
    return 0
}

# Функція для створення резервної копії конфігурації
backup_config() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="/root/lamp_backup_$timestamp"
    
    log "INFO" "Створення резервної копії конфігурації..."
    mkdir -p "$backup_dir"
    
    [[ -d "/etc/apache2" ]] && cp -r /etc/apache2 "$backup_dir/"
    [[ -d "/etc/mysql" ]] && cp -r /etc/mysql "$backup_dir/"
    [[ -f "/etc/php/*/apache2/php.ini" ]] && cp /etc/php/*/apache2/php.ini "$backup_dir/"
    
    log "SUCCESS" "Резервна копія створена в $backup_dir"
}

# Функція для оптимізації Apache
optimize_apache() {
    log "INFO" "Оптимізація Apache..."
    
    a2enmod expires headers deflate http2
    
    cat > /etc/apache2/mods-available/mpm_event.conf <<EOF
<IfModule mpm_event_module>
    StartServers             3
    MinSpareThreads         25
    MaxSpareThreads         75
    ThreadLimit            64
    ThreadsPerChild        25
    MaxRequestWorkers     150
    MaxConnectionsPerChild   0
</IfModule>
EOF
    
    a2dismod mpm_prefork
    a2enmod mpm_event
    
    systemctl restart apache2
    check_success "Не вдалося оптимізувати Apache"
}

# Функція для оптимізації MariaDB
optimize_mariadb() {
    log "INFO" "Оптимізація MariaDB..."
    
    cat > /etc/mysql/conf.d/optimizations.cnf <<EOF
[mysqld]
innodb_buffer_pool_size = 256M
innodb_log_file_size = 64M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
key_buffer_size = 32M
max_connections = 100
query_cache_size = 32M
query_cache_limit = 1M
EOF
    
    systemctl restart mariadb
    check_success "Не вдалося оптимізувати MariaDB"
}

# Функція для оптимізації PHP
optimize_php() {
    log "INFO" "Оптимізація PHP..."
    
    PHP_INI=$(php -i | grep "Loaded Configuration File" | awk '{print $5}')
    
    sed -i 's/memory_limit = .*/memory_limit = 256M/' "$PHP_INI"
    sed -i 's/max_execution_time = .*/max_execution_time = 300/' "$PHP_INI"
    sed -i 's/post_max_size = .*/post_max_size = 64M/' "$PHP_INI"
    sed -i 's/upload_max_filesize = .*/upload_max_filesize = 64M/' "$PHP_INI"
    sed -i 's/max_input_time = .*/max_input_time = 300/' "$PHP_INI"
    
    cat > /etc/php/*/mods-available/opcache.ini <<EOF
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
opcache.enable_cli=1
EOF
    
    systemctl restart apache2
    check_success "Не вдалося оптимізувати PHP"
}

# Основний код
main() {
    log "INFO" "Початок встановлення LAMP..."
    
    # Створення резервної копії
    backup_config
    
    # Встановлення змінних для уникнення інтерактивних запитів
    export DEBIAN_FRONTEND=noninteractive

    # Генерація паролів
    root_password=$(openssl rand -base64 12)
    phpmyadmin_password=$(openssl rand -base64 12)
    app_password=$(openssl rand -base64 12)

    # Налаштування phpMyAdmin
    debconf-set-selections <<EOF
phpmyadmin phpmyadmin/dbconfig-install boolean true
phpmyadmin phpmyadmin/app-password-confirm password $app_password
phpmyadmin phpmyadmin/mysql/admin-pass password $root_password
phpmyadmin phpmyadmin/mysql/app-pass password $app_password
phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2
EOF

    # Перевірка портів
    check_port 80 || log "WARNING" "Порт 80 зайнятий"
    check_port 3306 || log "WARNING" "Порт 3306 зайнятий"

    # Оновлення системи
    log "INFO" "Оновлення системи..."
    apt update && apt upgrade -y
    check_success "Не вдалося оновити систему"

    # Встановлення пакетів
    log "INFO" "Встановлення пакетів..."
    apt install -y apache2 mariadb-server mariadb-client php php-mysql php-mbstring php-zip php-gd php-json php-curl phpmyadmin
    check_success "Не вдалося встановити пакети"

    # Запуск сервісів
    systemctl start mariadb apache2
    systemctl enable mariadb apache2

    # Налаштування MariaDB
    mysql -u root <<EOF
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${root_password}');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

    # Створення користувача phpMyAdmin
    mysql -u root -p"${root_password}" <<EOF
CREATE USER IF NOT EXISTS 'admin'@'localhost' IDENTIFIED BY '${phpmyadmin_password}';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

    # Оптимізації
    optimize_apache
    optimize_mariadb
    optimize_php

    # Збереження інформації
    cat > /root/lamp_info.txt <<EOF
Дата встановлення: $(date)
MariaDB root password: ${root_password}
phpMyAdmin admin password: ${phpmyadmin_password}
Лог встановлення: ${LOG_FILE}
EOF
    chmod 600 /root/lamp_info.txt

    log "SUCCESS" "Встановлення LAMP завершено успішно!"
    
    # Вивід інформації
    echo -e "\n${GREEN}=== Інформація про встановлення ===${RESET}"
    echo -e "${BLUE}Логін (phpMyAdmin):${RESET} admin"
    echo -e "${BLUE}Пароль (phpMyAdmin):${RESET} ${GREEN}$phpmyadmin_password${RESET}"
    echo -e "${BLUE}Пароль root (MariaDB):${RESET} ${GREEN}$root_password${RESET}"
    echo -e "${BLUE}Адреса phpMyAdmin:${RESET} http://$(hostname -I | awk '{print $1}')/phpmyadmin"
    echo -e "${YELLOW}Інформація про встановлення збережена в /root/lamp_info.txt${RESET}"
    echo -e "${YELLOW}Лог встановлення доступний в ${LOG_FILE}${RESET}"
}

# Запуск основної функції
main
