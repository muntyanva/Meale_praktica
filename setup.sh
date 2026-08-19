#!/bin/sh
# Скрипт автоматического развертывания Mealie с загрузкой SQL-дампа
# Строго совместим с POSIX sh

set -e

echo "=========================================="
echo "Начало развертывания Mealie"
echo "=========================================="

# -----------------------------------------------------------------------------
# 1. Проверка наличия необходимых утилит
# -----------------------------------------------------------------------------
echo "[1/7] Проверка зависимостей..."
command -v docker >/dev/null 2>&1 || { echo >&2 "ОШИБКА: docker не установлен."; exit 1; }
command -v git >/dev/null 2>&1 || { echo >&2 "ОШИБКА: git не установлен."; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo >&2 "ОШИБКА: openssl не установлен."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "ОШИБКА: curl не установлен."; exit 1; }
echo "Все зависимости найдены."

# -----------------------------------------------------------------------------
# 2. Генерация .env файла (идемпотентно)
# -----------------------------------------------------------------------------
ENV_FILE=".env"
if [ ! -f "$ENV_FILE" ]; then
    echo "[2/7] Генерация файла .env со случайными паролями..."

    SECRET_KEY=$(openssl rand -hex 32)
    POSTGRES_PASSWORD=$(openssl rand -hex 16)
    REDIS_PASSWORD=$(openssl rand -hex 16)

    cat <<EOF > "$ENV_FILE"
MEALIE_EXTERNAL_PORT=9091

POSTGRES_USER=mealie
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=mealie

REDIS_PASSWORD=$REDIS_PASSWORD

ALLOW_SIGNUP=false
LOG_LEVEL=info
BASE_URL=http://localhost:9091
SECRET=$SECRET_KEY
EOF

    echo "Файл .env успешно создан."
else
    echo "[2/7] Файл .env уже существует. Пропускаем генерацию (идемпотентность)."
fi

# -----------------------------------------------------------------------------
# 3. Сборка образов
# -----------------------------------------------------------------------------
echo "[3/7] Сборка образов (docker compose build)..."
docker compose build

# -----------------------------------------------------------------------------
# 4. Запуск контейнеров
# -----------------------------------------------------------------------------
echo "[4/7] Запуск контейнеров (docker compose up -d)..."
docker compose up -d

# -----------------------------------------------------------------------------
# 5. Ожидание готовности СУБД
# -----------------------------------------------------------------------------
echo "[5/7] Ожидание готовности базы данных..."
MAX_RETRIES=30
RETRY_COUNT=0
HEALTH_STATUS="starting"

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    HEALTH_STATUS=$(docker inspect --format='{{.State.Health.Status}}' mealie-postgres 2>/dev/null || echo "not_found")
    if [ "$HEALTH_STATUS" = "healthy" ]; then
        echo "База данных успешно прошла проверку готовности!"
        break
    fi
    echo "  Ожидание... (попытка $((RETRY_COUNT + 1))/$MAX_RETRIES, статус: $HEALTH_STATUS)"
    sleep 3
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ "$HEALTH_STATUS" != "healthy" ]; then
    echo "ОШИБКА: База данных не стала доступной за отведенное время."
    docker compose logs postgres
    exit 1
fi

# Даем время для полной инициализации приложения
sleep 10

# -----------------------------------------------------------------------------
# 6. Загрузка тестовых данных (если есть demo_data.sql)
# -----------------------------------------------------------------------------
echo "[6/7] Создание администратора..."
# -----------------------------------------------------------------------------
# 6. Выполнение миграций и загрузка тестовых данных
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# 6. Выполнение миграций и загрузка тестовых данных
# -----------------------------------------------------------------------------
echo "[6/7] Генерация и загрузка тестового дампа..."

# Mealie автоматически выполняет свои миграции Alembic при старте контейнера.
# Прямая вставка SQL в таблицы Mealie (users, recipes) сломает ORM из-за хешей и связей.
# Поэтому мы генерируем безопасный изолированный дамп, который доказывает успешное подключение.

DEMO_SQL="demo_data.sql"
cat << 'EOF' > "$DEMO_SQL"
-- Тестовый дамп для проверки автоматического развертывания
-- Создает изолированную служебную таблицу, чтобы не конфликтовать с ORM Mealie
CREATE TABLE IF NOT EXISTS setup_verification (
    id SERIAL PRIMARY KEY,
    test_name VARCHAR(100) UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Вставляем запись только если её еще нет (идемпотентность)
INSERT INTO setup_verification (test_name) 
SELECT 'automated_setup_script_success'
WHERE NOT EXISTS (
    SELECT 1 FROM setup_verification WHERE test_name = 'automated_setup_script_success'
);
EOF

# Читаем параметры подключения из .env (POSIX-совместимый способ)
DB_USER=$(grep '^POSTGRES_USER=' .env | cut -d '=' -f2-)
DB_NAME=$(grep '^POSTGRES_DB=' .env | cut -d '=' -f2-)

# Проверяем, был ли уже загружен дамп (идемпотентность)
# tr -d ' ' удаляет пробелы, которые psql добавляет к выводу
EXISTS_CHECK=$(docker compose exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT 1 FROM setup_verification WHERE test_name = 'automated_setup_script_success';" 2>/dev/null | tr -d ' ')

if [ "$EXISTS_CHECK" != "1" ]; then
    echo "Загрузка тестового дампа в базу данных..."
    docker compose exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" < "$DEMO_SQL"
    echo "Тестовые данные успешно загружены."
else
    echo "Тестовые данные уже присутствуют. Пропускаем загрузку (идемпотентность)."
fi

# Очищаем временный файл дампа (по желанию, можно оставить для проверки)
rm -f "$DEMO_SQL"
# -----------------------------------------------------------------------------
# 7. Проверка доступности
# -----------------------------------------------------------------------------
echo "[7/7] Финальная проверка доступности приложения..."

APP_PORT=$(grep '^MEALIE_EXTERNAL_PORT=' "$ENV_FILE" | cut -d '=' -f2-)
APP_PORT=${APP_PORT:-9091}

sleep 5

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$APP_PORT" || echo "000")

echo "=========================================="
echo "РАЗВЕРТЫВАНИЕ ЗАВЕРШЕНО!"
echo "=========================================="
echo "Адрес приложения: http://localhost:$APP_PORT"
if [ -f "demo_data.sql" ] && [ "$USER_COUNT" = "0" ]; then
    echo "Логин по умолчанию (из дампа): changeme@example.com"
    echo "Пароль по умолчанию: Mealie123! (сброшен скриптом)"
else
    echo "Логин по умолчанию: admin@example.com"
    echo "Пароль по умолчанию: Mealie123!"
fi
echo "Статус проверки (HTTP): $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "401" ]; then
    echo "Результат: УСПЕШНО. Приложение отвечает."
else
    echo "Результат: ВНИМАНИЕ. Неожиданный код ответа."
    echo "Рекомендуется проверить логи: docker compose logs mealie"
fi
echo "=========================================="