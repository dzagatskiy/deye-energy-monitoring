# Deye Cloud → TelemetrySample: мапінг полів

Джерело: реальні відповіді Deye Cloud OpenAPI (регіон EU) для SUN-6K-SG03LP1, записані 2026-11-23 о 18:21 (Київ)
скриптом `scripts/deye_spike.py`. Знеособлені копії лежать у `Packages/EnergyCore/Tests/EnergyCoreTests/Fixtures/DeyeCloud/`.
На момент запису **на дачі не було мережі**, тож це знімок стану GRID OFF.

## Підтверджене

| Що | Факт |
|---|---|
| Токен | `POST /account/token?appId=…` → `accessToken`, `refreshToken`, `expiresIn` = `"5183999"` (рядок, ≈ 60 діб) |
| Формат помилок | HTTP завжди 200; успіх визначає `code == "1000000"` і `success == true` |
| `2101019` "auth invalid token" | Цей код повертає `/device/list` для особистого акаунта навіть із робочим токеном |
| `2101007` "list too long" | `/device/history`: 10 `measurePoints` відхилено, 5 прийнято. Застосунок шле батчами по ≤5 |
| Історія | `POST /device/history {deviceSn, granularity:1, startAt/endAt:"yyyy-MM-dd", measurePoints}` → `dataList[] = {time: "unix-сек рядком", itemList[] = {key, value, unit}}` |
| Крок історії | Медіана **343 с (~5.7 хв)**, 235 кадрів за добу. Розриви до 2 год 2 хв трапляються |
| `GridStatus` | Запит приймається, але в кадрах історії і в `/device/latest` значення ніколи не повертається |
| Пошук інвертора | `POST /station/listWithDevice {page, size, deviceType:"INVERTER"}` → `stationList[].deviceListItems[] = {deviceSn, connectStatus, collectionTime, …}` |
| Realtime | `POST /device/latest {deviceList:[sn]}` → `deviceDataList[].dataList[] = {key, value: String, unit}` |
| Час виміру | `collectionTime`, Unix-секунди. Під час запису дані були приблизно 3 хв давнини |
| Метрики | `POST /device/measurePoints {deviceSn}` повертає 73 ключі, серед них `GridStatus` і `GridRelayStatus` |
| Rate-limit заголовки | У відповідях не з'явилися. Неофіційно: близько 60 запитів/хв і 100k/міс (deyecloud-skills, "preliminary") |

## Мапінг

| TelemetrySample | Ключ Deye | Зразок (GRID OFF) | Примітка |
|---|---|---|---|
| `gridState` | `GridRelayStatus` | `"Break"` / `"Pull-in"` | `Break` означає OFF (4.5 V, 0 Hz). `Pull-in` означає ON (230.5 V, 50.03 Hz), але береться лише тоді, коли немає напруги, яка йому суперечить |
| `gridVoltage` | `GridVoltageL1L2` | `4.50 V` | Залишкова наводка, тому поріг 170 V має запас |
| `gridPower` | `TotalGridPower` | `0 W` / `79 W` | Під час заряду від мережі `+79 W`, отже «+» означає імпорт. Перевірено на одному знімку |
| `batterySOC` | `SOC` | `92 %` | `BMSSOC` дублює значення |
| `batteryVoltage` | `BatteryVoltage` | `52.95 V` | |
| `batteryCurrent` | `BatteryCurrent` | `3.98 A` | Знак інвертується |
| `batteryPower` | `BatteryPower` | `210 W` / `−29 W` | **У Deye «+» означає розряд, «−» означає заряд.** Без мережі при PV = 0 і навантаженні 220 W було +210 W. З мережею при SOC 98% було −29 W. Застосунок інвертує знак |
| `loadPower` | `TotalConsumptionPower` | `220 W` | Резерв: `UPSLoadPower` |
| `pvPower` | `TotalDCInputPower` | `0 W` | Резерв: сума `DCPowerPV1…4` |
| `dailyLoadEnergy` | `DailyConsumption` | `4.30 kWh` | Для звірки з власним інтегруванням |
| ємність (Settings) | `BatteryRatedCapacity` | `300 Ah` | × 51.2 V = 15.36 kWh, підставляється як підказка |

`deviceState` (`1`) не документований, тому не використовується.

## Відкриті питання

1. **Кілька інверторів:** вирішено в [ADR 0001](adr/0001-multiple-inverters.md). Кожен віджет показує вибраний інвертор. Станція `Asia/Beirut` онлайн, у ній було відключення 2026-11-23 о 18:18. Станція `Europe/Helsinki` перестала надсилати дані приблизно о 16:50.
2. Кадр історії з реальним відключенням поки не записаний. Третій запуск скрипта (тепер він обирає онлайн-інвертор) дасть історію дачі за сьогодні, з переходом ON→OFF.
3. Точна межа `measurePoints` в одному запиті (від 5 до 9) — не критично, батчі по 5 працюють.
4. `deviceState` спостерігався зі значеннями `1` (онлайн, без мережі) і `3` (дані застаріли). Документації немає, не використовується.

## Інше

- Ліміти (рекомендація Deye): не більше **60 запитів/хв** на застосунок і опитування раз на **1–2 хв**. Квота ~100k/міс неофіційна.
  - Усі запити клієнта проходять через `RequestRateLimiter`, ковзне вікно 60 с. Застосунок має бюджет 50/хв, віджет 10/хв, бо в нього окремий процес. Сумарно це не більше 60.
  - HTTP 429 зупиняє всі запити на `Retry-After` (або 60 с). Віджет не чекає вільного слота довше 5 с і показує останні дані.
  - Інтервал опитування в застосунку можна вибрати серед 1, 2 (за замовчуванням) і 5 хв. Збережене значення обмежується діапазоном 1–10 хв.
  - Одне оновлення робить 1 запит `/device/latest` на інвертор, а раз на 30 хв ще 2 запити історії на кожен день. При 2 хв і двох інверторах це в середньому ~1 запит/хв, тобто ~43k/міс, якщо застосунок відкритий цілодобово.
- Часовий пояс станції в Deye застосунок ігнорує й рахує добу за власним налаштуванням (Europe/Kyiv).
