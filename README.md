<a href="https://infostart.ru/public/2779597/"><img src="https://infostart.ru/bitrix/templates/sandbox_empty/assets/tpl/abo/img/logo.svg" alt="Infostart" style="vertical-align: middle;"></a> - Первая часть

<br>

<a href="https://infostart.ru/public/2780378/"><img src="https://infostart.ru/bitrix/templates/sandbox_empty/assets/tpl/abo/img/logo.svg" alt="Infostart" style="vertical-align: middle;"></a> - Вторая часть

<br>

<a href="https://infostart.ru/public/2781587/"><img src="https://infostart.ru/bitrix/templates/sandbox_empty/assets/tpl/abo/img/logo.svg" alt="Infostart" style="vertical-align: middle;"></a> - Третья часть

<br>

<a href="https://infostart.ru/public/2783161/"><img src="https://infostart.ru/bitrix/templates/sandbox_empty/assets/tpl/abo/img/logo.svg" alt="Infostart" style="vertical-align: middle;"></a> - Четвертая часть

<br>

<a href="https://infostart.ru/public/2790159/"><img src="https://infostart.ru/bitrix/templates/sandbox_empty/assets/tpl/abo/img/logo.svg" alt="Infostart" style="vertical-align: middle;"></a> - Пятая часть



# DevOps & Stability Enterprise Suite for 1C on Linux

Комплекс инструментов обеспечения надежности, непрерывной интеграции (CI/CD) и автоматизированной эксплуатации крупных кластеров «1С:Предприятие 8.3» на платформе Linux.

## 📂 Структура репозитория

* `ansible/` — Ansible-роли для автоматизированного развёртывания инфраструктуры.
  * `patroni-ha/` — роль развёртывания отказоустойчивого кластера PostgreSQL Pro 1C (Patroni + etcd + vip-manager).
* `config/` — оптимизированные шаблоны настроек технологического журнала и HASP-лицензирования.
* `docker/` — Dockerfile для сборки сборочных агентов с графическим стеком (Xvfb) и шрифтами.
* `docs/` — статьи и иллюстрации.
  * `articles/` — HTML-статьи цикла публикаций «SRE-Suite-for-1C-platform».
  * `assets/` — изображения к статьям.
  * [`STYLE_GUIDE.md`](docs/STYLE_GUIDE.md) — единый визуальный и текстовый стандарт цикла: шаблоны HTML-блоков, тон, правила соответствия Infostart.ru. Обязателен к прочтению перед любой новой статьёй серии.
* `orchestrator/` — комплект SRE-инструментов для ротации rphost и алертинга.
* `scripts/` — скрипты сборки, маскирования данных и конвертации метаданных из EDT в формат Конфигуратора.

## 🚀 Быстрый старт

### 1. Сборка Docker-образа
Для подготовки сборочного раннера поместите deb-дистрибутивы платформы 1С в подкаталог `docker/dist` и выполните:
```bash
docker build -t 1c-ci-runner:latest ./docker
```

### 2. Запуск синтаксического контроля
Скрипт проверяет код BSL во всех контекстах и реализует 5 рубежей защиты:
```bash
./scripts/1c-ci-linux-build-v4.sh -c "/F/tmp/build_db" -e "MyExtension" -u "Admin" -w "SecurePass" -s "./src/extension"
```

### 3. Настройка SRE-мониторинга
Установите службу автоматического выявления "перестарков" на сервере 1С:
```bash
cd orchestrator
sudo ./install_admincluster.sh
```
Настройте параметры в `/etc/admincluster/config.conf` и активируйте таймер systemd:
```bash
sudo systemctl enable --now admincluster-monitor@prod.timer
```

### 4. Развёртывание отказоустойчивого кластера PostgreSQL (Patroni + etcd + vip-manager)
Подробное описание архитектуры — в [четвёртой части цикла](https://infostart.ru/1c/articles/2783161/). Аутентификация к серверам — по SSH-ключам; пароли самой СУБД задаются через Ansible Vault и в открытом виде в репозитории не хранятся:
```bash
cd ansible/patroni-ha
cp group_vars/db_nodes/vault.yml.example group_vars/db_nodes/vault.yml
# отредактируйте vault.yml, подставив свои пароли, затем:
ansible-vault encrypt group_vars/db_nodes/vault.yml
# отредактируйте hosts.ini под свою сеть (IP-адреса узлов и VIP, pg_hba_subnet), затем:
ansible-playbook -i hosts.ini deploy-cluster.yml --ask-vault-pass
```

### 5. Тюнинг ядра Linux и экспресс-диагностика PostgreSQL + 1С
Подробный разбор параметров `sysctl`, отключения THP и практик снижения I/O-ступоров — в [пятой части цикла](https://infostart.ru/1c/articles/2790159/). Для быстрой проверки состояния Linux, PostgreSQL и кластера 1С используйте встроенный диагностический скрипт:
```bash
chmod +x scripts/sre-1c-pg-healthcheck.sh
./scripts/sre-1c-pg-healthcheck.sh
```

---
Разработано для публикации на infostart.ru в рамках проекта «SRE-suite-for-1C-platform». Свободная лицензия MIT.
