#!/bin/sh
# Smoke test script для Mealie
# POSIX sh compatible (проверяется через sh -n smoke_test.sh)

APP_PORT=${MEALIE_EXTERNAL_PORT:-9091}
BASE_URL="http://localhost:$APP_PORT"

FAILED=0
PASSED=0

check_endpoint() {
    METHOD=$1
    URL=$2
    EXPECTED_CODE=$3
    DESCRIPTION=$4
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X "$METHOD" "$URL" 2>/dev/null || echo "000")
    
    if [ "$HTTP_CODE" = "$EXPECTED_CODE" ]; then
        echo "[OK] $METHOD $DESCRIPTION (HTTP $HTTP_CODE)"
        PASSED=$((PASSED + 1))
    else
        echo "[FAIL] $METHOD $DESCRIPTION (expected $EXPECTED_CODE, got $HTTP_CODE)"
        FAILED=$((FAILED + 1))
    fi
}

echo "=========================================="
echo "Запуск smoke-тестов Mealie"
echo "=========================================="

# Проверка 1: Главная страница приложения
check_endpoint "GET" "$BASE_URL/" "200" "Главная страница /"

# Проверка 2: API эндпоинт информации о приложении (публичный)
check_endpoint "GET" "$BASE_URL/api/app/about" "200" "API /api/app/about"

# Проверка 3: Swagger документация API
check_endpoint "GET" "$BASE_URL/docs" "200" "Swagger UI /docs"

echo "=========================================="
echo "Результаты: $PASSED пройдено, $FAILED провалено"
echo "=========================================="

if [ $FAILED -gt 0 ]; then
    echo "ОШИБКА: Некоторые проверки провалились!"
    exit 1
fi

echo "Все проверки пройдены успешно!"
exit 0