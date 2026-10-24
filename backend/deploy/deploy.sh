#!/usr/bin/env bash
# Развёртывание сервера в Yandex Cloud. Запускается из GitHub Actions (deploy-backend.yml).
# Скрипт идемпотентный: при повторном запуске создаёт только то, чего нет, и выкладывает новую версию функции.
#
# Нужно в окружении: yc и ydb (CLI) настроены на сервисный аккаунт github-deploy,
#   YC_FOLDER_ID, SA_KEY_FILE (путь к ключу), BUCKET, APP_SECRET, ADMIN_EMAILS
# Необязательно: YOOKASSA_SHOP_ID, YOOKASSA_SECRET_KEY, YOOKASSA_ALLOW_CARDS, RECEIPTS_ENABLED, RECEIPT_VAT_CODE,
#   TAX_SYSTEM_CODE, POSTBOX_ACCESS_KEY_ID, POSTBOX_SECRET_ACCESS_KEY, MAIL_FROM, CLUB_UTC_OFFSET

set -euo pipefail
cd "$(dirname "$0")/.."   # папка backend

DB_NAME=tkd-db
FN_NAME=tkd-api
GW_NAME=tkd-gw
RUNTIME_SA=tkd-backend
SITE="https://${BUCKET}.website.yandexcloud.net"

step() { echo; echo "=== $* ==="; }
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$*" >> "$GITHUB_STEP_SUMMARY" || true; }

# ---------- 1. Сервисный аккаунт, от имени которого работает функция ----------
step "Сервисный аккаунт $RUNTIME_SA"
SA_ID=$(yc iam service-account get --name "$RUNTIME_SA" --format json 2>/dev/null | jq -r '.id // empty' || true)
if [ -z "$SA_ID" ]; then
  SA_ID=$(yc iam service-account create --name "$RUNTIME_SA" --description "Сервер приложения секции" --format json | jq -r .id)
  echo "Создан: $SA_ID"
fi
BINDINGS=$(yc resource-manager folder list-access-bindings --id "$YC_FOLDER_ID" --format json)
for ROLE in ydb.editor functions.functionInvoker postbox.sender; do
  if echo "$BINDINGS" | jq -e --arg r "$ROLE" --arg s "$SA_ID" '.[] | select(.role_id == $r and .subject.id == $s)' >/dev/null; then
    echo "Роль $ROLE уже есть"
  else
    yc resource-manager folder add-access-binding --id "$YC_FOLDER_ID" --role "$ROLE" --subject "serviceAccount:$SA_ID" >/dev/null
    echo "Выдана роль $ROLE"
  fi
done

# ---------- 2. База данных YDB (serverless) ----------
step "База данных $DB_NAME"
if ! yc ydb database get --name "$DB_NAME" >/dev/null 2>&1; then
  yc ydb database create --name "$DB_NAME" --serverless --description "Данные приложения секции" >/dev/null
  echo "Создаётся…"
fi
for _ in $(seq 1 60); do
  STATUS=$(yc ydb database get --name "$DB_NAME" --format json | jq -r .status)
  [ "$STATUS" = "RUNNING" ] && break
  echo "Статус: $STATUS, ждём…"; sleep 10
done
[ "$STATUS" = "RUNNING" ] || { echo "::error::База не запустилась (статус $STATUS)"; exit 1; }
FULL_ENDPOINT=$(yc ydb database get --name "$DB_NAME" --format json | jq -r .endpoint)
YDB_ENDPOINT="${FULL_ENDPOINT%%/?database=*}"
YDB_DATABASE="${FULL_ENDPOINT##*database=}"
echo "endpoint=$YDB_ENDPOINT database=$YDB_DATABASE"

step "Таблицы"
node scripts/gen-schema.js > "$RUNNER_TEMP/schema.yql"
YDB=(ydb -e "$YDB_ENDPOINT" -d "$YDB_DATABASE" --sa-key-file "$SA_KEY_FILE")
if ! "${YDB[@]}" sql -f "$RUNNER_TEMP/schema.yql" 2>"$RUNNER_TEMP/ydb.err"; then
  cat "$RUNNER_TEMP/ydb.err"
  echo "Пробую старую команду ydb yql…"
  "${YDB[@]}" yql -f "$RUNNER_TEMP/schema.yql"
fi
"${YDB[@]}" scheme ls

# ---------- 3. Облачная функция ----------
step "Функция $FN_NAME"
yc serverless function get --name "$FN_NAME" >/dev/null 2>&1 || yc serverless function create --name "$FN_NAME" --description "API приложения секции" >/dev/null
FN_ID=$(yc serverless function get --name "$FN_NAME" --format json | jq -r .id)

RUNTIME=nodejs22
if ! yc serverless function runtime list --format json | jq -e '.[] | select(. == "nodejs22")' >/dev/null 2>&1; then RUNTIME=nodejs20; fi
echo "Среда: $RUNTIME"

# Код + package.json; зависимости (ydb-sdk) облако установит само.
npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null
rm -f "$RUNNER_TEMP/fn.zip"
zip -qr "$RUNNER_TEMP/fn.zip" package.json package-lock.json src
ls -la "$RUNNER_TEMP/fn.zip"

ENV="YDB_ENDPOINT=$YDB_ENDPOINT,YDB_DATABASE=$YDB_DATABASE,YDB_METADATA_CREDENTIALS=1"
ENV+=",APP_SECRET=$APP_SECRET,ADMIN_EMAILS=${ADMIN_EMAILS:-},RETURN_URL=$SITE/web/paid.html,CORS_ORIGIN=*"
ENV+=",CLUB_UTC_OFFSET=${CLUB_UTC_OFFSET:-3}"
add_env() { [ -n "${!1:-}" ] && ENV+=",$1=${!1}" || true; }
for V in YOOKASSA_SHOP_ID YOOKASSA_SECRET_KEY YOOKASSA_ALLOW_CARDS RECEIPTS_ENABLED RECEIPT_VAT_CODE TAX_SYSTEM_CODE \
         POSTBOX_ACCESS_KEY_ID POSTBOX_SECRET_ACCESS_KEY MAIL_FROM; do
  add_env "$V"
done

yc serverless function version create \
  --function-id "$FN_ID" \
  --runtime "$RUNTIME" \
  --entrypoint src/handler.handler \
  --memory 256m \
  --execution-timeout 30s \
  --service-account-id "$SA_ID" \
  --source-path "$RUNNER_TEMP/fn.zip" \
  --environment "$ENV" >/dev/null
echo "Новая версия функции выложена"

# ---------- 4. API Gateway ----------
step "API Gateway $GW_NAME"
sed -e "s/FUNCTION_ID/$FN_ID/" -e "s/SERVICE_ACCOUNT_ID/$SA_ID/" deploy/api-gateway.yaml > "$RUNNER_TEMP/gw.yaml"
if yc serverless api-gateway get --name "$GW_NAME" >/dev/null 2>&1; then
  yc serverless api-gateway update --name "$GW_NAME" --spec "$RUNNER_TEMP/gw.yaml" >/dev/null
else
  yc serverless api-gateway create --name "$GW_NAME" --spec "$RUNNER_TEMP/gw.yaml" --description "API приложения секции" >/dev/null
fi
API_URL="https://$(yc serverless api-gateway get --name "$GW_NAME" --format json | jq -r .domain)"
echo "API: $API_URL"

# ---------- 5. Хранилище для APK и веб-версии ----------
step "Хранилище $BUCKET"
if ! yc storage bucket get --name "$BUCKET" >/dev/null 2>&1; then
  yc storage bucket create --name "$BUCKET" --default-storage-class standard --max-size 2147483648 >/dev/null
  echo "Создано"
fi
yc storage bucket update --name "$BUCKET" --public-read --website-settings '{"index": "index.html", "error": "index.html"}' >/dev/null
echo "Сайт: $SITE"

# ---------- 6. Проверка ----------
step "Проверка"
OK=""
for _ in $(seq 1 12); do
  if curl -fsS "$API_URL/health" | grep -q '"ok":true'; then OK=1; break; fi
  sleep 10   # первый запуск функции ставит зависимости
done
[ -n "$OK" ] || { echo "::error::Сервер не отвечает на $API_URL/health. Логи: консоль → Cloud Functions → $FN_NAME → Логи"; exit 1; }
echo "Сервер отвечает ✅"

summary "### Сервер развёрнут ✅"
summary "- API: \`$API_URL\`"
summary "- Хранилище приложения: $SITE"
summary "- Уведомления ЮKassa: \`$API_URL/webhooks/yookassa\`"
[ -z "${ADMIN_EMAILS:-}" ] && summary "- ⚠️ Не задана переменная ADMIN_EMAILS — администратора нет" || true
[ -z "${POSTBOX_ACCESS_KEY_ID:-}" ] && summary "- ⚠️ Почта (Postbox) не подключена — коды входа видны только в логах функции" || true
[ -z "${YOOKASSA_SHOP_ID:-}" ] && summary "- ⚠️ ЮKassa не подключена — онлайн-оплата выключена" || true
