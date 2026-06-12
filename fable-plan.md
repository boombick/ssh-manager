# План исправлений SSH Manager

> **Для агентов-исполнителей:** РЕКОМЕНДУЕМЫЙ НАВЫК: superpowers:subagent-driven-development или superpowers:executing-plans — выполнять план задача за задачей. Шаги размечены чекбоксами (`- [ ]`).

**Цель:** исправить найденные при аудите функциональные баги, гонки, утечки и устаревшие тексты в macOS menu-bar приложении SSH Manager, не меняя его архитектуру.

**Архитектура (как есть):** Приложение на Swift 6 (language mode v5), SwiftPM, без внешних зависимостей. AppKit (меню-бар) + SwiftUI (окно управления). Каждое соединение обслуживает `TunnelEngine`: он запускает дочерний процесс `/usr/bin/ssh` и поднимает рядом in-process TCP-прокси (`ProxyServer`) для подсчёта байтов; пользовательский порт слушает прокси, а ssh слушает порт `+10000`. `TunnelSupervisor` владеет всеми движками, пишет историю (SQLite через `HistoryStore`/`Database`) и пингует хосты (`PingMonitor` — TCP-handshake к ssh-порту каждые 10 с).

**Стек:** Swift 6 toolchain, SwiftPM, AppKit, SwiftUI, Network.framework, SQLite3 (системная), Charts.

**Сборка и проверка:**
```sh
swift build                      # компиляция (главная проверка каждой задачи)
swift test                       # после задачи 0 — юнит-тесты
./scripts/build-app.sh           # собрать .app для ручной проверки
open ./SSHManager.app
```

**Карта исходников (все пути от корня репозитория):**

| Файл | Ответственность |
|---|---|
| `Sources/SSHManager/main.swift` | Точка входа, NSApplication accessory |
| `Sources/SSHManager/AppDelegate.swift` | Создание supervisor/окна/меню, остановка при выходе |
| `Sources/SSHManager/Models/Connection.swift` | Модель соединения + Codable |
| `Sources/SSHManager/Storage/ConfigStore.swift` | Чтение/запись config.json |
| `Sources/SSHManager/Storage/Paths.swift` | Пути в ~/Library/Application Support/SSHManager |
| `Sources/SSHManager/Storage/LoginItem.swift` | SMAppService «open at login» |
| `Sources/SSHManager/Tunnel/TunnelEngine.swift` | Жизненный цикл одного ssh-туннеля + реконнект + логи |
| `Sources/SSHManager/Tunnel/TunnelSupervisor.swift` | Владеет движками, CRUD, история, пинги, статистика |
| `Sources/SSHManager/Tunnel/ProxyServer.swift` | TCP-прокси со счётчиком байтов |
| `Sources/SSHManager/Tunnel/HttpProxyServer.swift` | HTTP CONNECT → SOCKS5 прокси |
| `Sources/SSHManager/Tunnel/PingMonitor.swift` | TCP-«пинг» хостов |
| `Sources/SSHManager/History/Database.swift` | Обёртка sqlite3 |
| `Sources/SSHManager/History/HistoryStore.swift` | Сэмплы/события/аптайм |
| `Sources/SSHManager/UI/MenuBarController.swift` | NSStatusItem меню |
| `Sources/SSHManager/UI/MainWindowController.swift` | Окно «Manage Connections» |
| `Sources/SSHManager/UI/ConnectionListView.swift` | Список соединений (SwiftUI) |
| `Sources/SSHManager/UI/ConnectionEditView.swift` | Форма добавления/редактирования |
| `Sources/SSHManager/UI/StatsView.swift` | Графики и события |

**Правила для исполнителя:**
- После каждой задачи: `swift build` (и `swift test` после задачи 0) должны проходить; затем коммит.
- Номера строк в задачах соответствуют состоянию репозитория на коммите `90d23b8` и сдвигаются по мере выполнения — ориентируйся на приведённые фрагменты кода, а не только на номера.
- Не делать рефакторингов сверх описанного.

---

## Сводка найденных проблем (по приоритету)

**P1 — ломают основные сценарии:**
1. Кнопка «Stop» в состоянии reconnecting фактически ЗАПУСКАЕТ попытку подключения (инвертированный toggle).
2. Реконнект может «зависнуть» навсегда: таймер ретрая срабатывает, пока старый ssh-процесс ещё не умер, и `start()` молча выходит.
3. История никогда не фиксирует обрывы туннеля при `autoReconnect=true` (а это значение по умолчанию) → в статистике Fails=0 и аптайм завышен.
4. `ProxyServer` и `HttpProxyServer` слушают на всех интерфейсах (0.0.0.0) — SOCKS/HTTP-прокси доступны из локальной сети без аутентификации.

**P2 — серьёзные дефекты:**
5. Крэш приложения при невалидном порте в руками отредактированном config.json (`UInt16(...)` трапается; меню само предлагает «Edit config.json…» + «Reload Config»).
6. `updateConnection` перезапускает движок наперегонки со смертью старого ssh → новый бинд порта падает (без autoReconnect — сразу `.failed`).
7. При выходе из приложения события `.stopped` не попадают в историю → после перезапуска статистика считает туннель «работавшим» всё время простоя.
8. Лог соединения обнуляется при каждом старте, включая каждую попытку реконнекта → диагностировать цикл реконнектов по логу невозможно.

**P3 — заметные дефекты качества:**
9. `StatsView` перечитывает всю выборку из SQLite при каждом тике supervisor (каждые 0.5 с); на диапазоне 30d это ~260 тыс. строк синхронно на main-потоке.
10. Меню статус-бара пересоздаётся при каждом изменении (каждые 0.5 с при трафике), в том числе пока открыто.
11. Устаревшие тексты: подсказка у тумблера «Auto-reconnect» говорит «Currently has no effect», README описывает только «Phase 1» — оба врут, фичи реализованы.
12. Сэмплы пишутся в SQLite каждые 10 с для ВСЕХ соединений, включая остановленные (~8.6 тыс. строк/сутки на соединение впустую).

**P4 — мелочи и чистка:**
13. Поле `PingResult.updatedAt` нигде не читается (мёртвый код).
14. Окно статистики остаётся открытым со стейлом после удаления соединения.
15. `HttpProxyServer` теряет байты клиента, пришедшие в одном пакете с заголовками CONNECT (early data).
16. `ProxyServer` не закрывает NWConnection после чистого двустороннего завершения — медленная утечка.
17. Валидация формы не запрещает HTTP-порту совпадать с внутренним ssh-портом (`listenPort + 10000`).

---

### Задача 0: Тестовый таргет

Сейчас тестов нет вообще. Добавляем таргет, чтобы задачи 3 и 5 можно было покрыть юнит-тестами (история и планирование туннеля — чистая логика).

**Файлы:**
- Изменить: `Package.swift`
- Создать: `Tests/SSHManagerTests/SmokeTests.swift`

- [ ] **Шаг 0.1: Добавить testTarget в Package.swift**

Заменить блок `targets:` целиком на:

```swift
    targets: [
        .executableTarget(
            name: "SSHManager",
            path: "Sources/SSHManager",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "SSHManagerTests",
            dependencies: ["SSHManager"],
            path: "Tests/SSHManagerTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
```

- [ ] **Шаг 0.2: Дымовой тест**

Создать `Tests/SSHManagerTests/SmokeTests.swift`:

```swift
import XCTest
@testable import SSHManager

final class SmokeTests: XCTestCase {
    func testConnectionBlankDefaults() {
        let c = Connection.blank()
        XCTAssertEqual(c.type, .dynamic)
        XCTAssertEqual(c.listenPort, 1080)
        XCTAssertTrue(c.autoReconnect)
        XCTAssertFalse(c.httpProxyEnabled)
    }
}
```

- [ ] **Шаг 0.3: Проверить**

Запустить: `swift test`
Ожидается: PASS (1 тест). Примечание: SwiftPM с 5.5 позволяет testTarget зависеть от executable-таргета; top-level код `main.swift` при линковке тестов не выполняется как тест, но XCTest-раннер на macOS может его исполнить при запуске бандла — если `swift test` зависнет/упадёт из-за `app.run()` в `main.swift`, обернуть содержимое `main.swift` так:

```swift
import AppKit

// Не запускаем NSApplication внутри тестового раннера.
if NSClassFromString("XCTestCase") == nil {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
```

(Глобальная переменная `delegate` обязана остаться сильной ссылкой внутри ветки — приведённый вариант это сохраняет, т.к. `app.run()` не возвращается.)

- [ ] **Шаг 0.4: Коммит**

```sh
git add Package.swift Tests/SSHManagerTests/SmokeTests.swift Sources/SSHManager/main.swift
git commit -m "test: add SSHManagerTests target with smoke test"
```

---

### Задача 1 (P1): «Stop» во время реконнекта запускает туннель

**Проблема.** `TunnelSupervisor.toggle(id:)` (Sources/SSHManager/Tunnel/TunnelSupervisor.swift:144-151) решает «стоп или старт» по `state.isRunning`. Для `.reconnecting` `isRunning == false`, поэтому кнопка «Stop» в строке соединения (`ConnectionListView.swift:267-272`, case `.reconnecting`) и клик по пункту меню вызывают `engine.start()` — то есть немедленную попытку подключения вместо остановки.

**Файлы:**
- Изменить: `Sources/SSHManager/Tunnel/TunnelSupervisor.swift:144-151`

- [ ] **Шаг 1.1: Исправить toggle**

Заменить:

```swift
    func toggle(id: UUID) {
        guard let e = engines[id] else { return }
        if e.state.isRunning {
            e.stop()
        } else {
            e.start()
        }
    }
```

на:

```swift
    func toggle(id: UUID) {
        guard let e = engines[id] else { return }
        switch e.state {
        case .running, .reconnecting:
            e.stop()
        case .stopped, .failed:
            e.start()
        }
    }
```

- [ ] **Шаг 1.2: Сборка**

Запустить: `swift build`
Ожидается: Build complete.

- [ ] **Шаг 1.3: Ручная проверка**

Собрать `./scripts/build-app.sh`, открыть приложение, создать соединение с несуществующим хостом (например, host `127.0.0.1`, sshPort `1`, autoReconnect on), нажать Start. Когда строка покажет «Reconnecting (attempt N…)», нажать «Stop». Ожидается: состояние становится «stopped» (серый кружок), новых попыток нет. До исправления нажатие «Stop» запускало немедленную попытку коннекта.

- [ ] **Шаг 1.4: Коммит**

```sh
git add Sources/SSHManager/Tunnel/TunnelSupervisor.swift
git commit -m "fix: Stop during reconnecting actually stops instead of starting"
```

### Задача 2 (P1): Реконнект зависает навсегда

**Файлы:** `Sources/SSHManager/Tunnel/TunnelEngine.swift`

**Суть.** `start()` начинается с `guard process == nil else { return }` (строка 71). Пути сбоя `handleProxyFailure` (246-261), `handleHttpProxyFailure` (300-309) и catch сбоя HTTP-прокси в `start()` (164-175) делают `process?.terminate()` и планируют ретрай, но НЕ обнуляют `process` — его обнуляет только асинхронный `handleTermination`. Если таймер ретрая (2 с) сработает раньше, чем ssh умрёт (завис, игнорирует SIGTERM), `start()` молча выйдет, `retryTimer` уже nil → состояние навсегда `.reconnecting`. То же ломает `retryNow()`.

**Исправление.**
1. В трёх перечисленных путях сбоя после `process?.terminate()` добавить `process = nil`.
2. Чтобы осиротевший terminationHandler старого процесса не разрушил новый запуск: передавать процесс в обработчик — `handleTermination(of: proc, exitCode:)` — и в его начале делать `guard proc === process else { return }`.

---

### Задача 3 (P1): История не видит обрывов при autoReconnect

**Файлы:** `Sources/SSHManager/Tunnel/TunnelSupervisor.swift:83-97`; тест в `Tests/SSHManagerTests/HistoryStoreTests.swift`

**Суть.** `recordStateChangeEvent` для `.reconnecting` ничего не пишет (комментарий ссылается на «обрамляющие .failed события», но при `autoReconnect=true` — дефолт — переход идёт `.running → .reconnecting` минуя `.failed`). Итог: Fails в статистике всегда 0, аптайм завышен.

**Исправление.** В ветке `.reconnecting(_, _, let lastError)` писать `history.recordEvent(connectionId:, kind: .failed, message: lastError)`. Тест: temp-БД HistoryStore, события started/failed/started, проверить `summary().failCount == 1` и `uptimeFraction ≈ 0.75`. Для ожидания асинхронных записей добавить в HistoryStore метод `flush() { queue.sync {} }` (пригодится и в задаче 7).

---

### Задача 4 (P1): Прокси слушают 0.0.0.0

**Файлы:** `Sources/SSHManager/Tunnel/ProxyServer.swift:33-55`, `Sources/SSHManager/Tunnel/HttpProxyServer.swift:29-48`

**Суть.** `NWListener(using:on:)` без привязки к адресу биндится на все интерфейсы — SOCKS/HTTP-прокси и внутренний порт `-R` доступны из LAN без аутентификации (открытый relay).

**Исправление.** В обоих `start()`: `params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)` и `NWListener(using: params)` без `on:`. Заодно заменить `UInt16(listenPort)` на `UInt16(exactly:)` с guard (см. задачу 5). Проверка: `netstat -an | grep LISTEN | grep <порт>` → должен быть `127.0.0.1.<порт>`, не `*.<порт>`.

---

### Задача 5 (P2): Крэш на невалидном порте из config.json

**Файлы:** `Sources/SSHManager/Tunnel/ProxyServer.swift:37,66-68`, `Sources/SSHManager/Tunnel/HttpProxyServer.swift:33,156`, `Sources/SSHManager/Tunnel/TunnelEngine.swift:407-458`

**Суть.** Конфиг редактируется руками (меню «Edit config.json…» + «Reload Config»), но порты валидируются только в UI-форме. `UInt16(listenPort)` при значении вне 0...65535 трапается → крэш всего приложения. Места: `ProxyServer.start` и `accept` (force-unwrap `NWEndpoint.Port(...)!`), `HttpProxyServer.connectViaSocks`, плюс `planTunnel` не проверяет `listenPort`/`sshPort` снизу и `listenPort` для `.remote` вообще.

**Исправление.** В `planTunnel()` добавить guard'ы: `(1...65535).contains(connection.listenPort)`, `(1...65535).contains(connection.sshPort)`, для `.local`/`.remote` — `remotePort` в том же диапазоне; новый кейс `PlanError.portOutOfRange` с внятным описанием → соединение уйдёт в `.failed` с сообщением вместо крэша. В ProxyServer/HttpProxyServer все конверсии портов через `UInt16(exactly:)` с guard/ранним выходом. Тест: сделать `planTunnel()` и `TunnelPlan` internal, проверить что листен-порт 70000 кидает ошибку, а валидный `.dynamic` даёт ожидаемые ssh-аргументы.

---

### Задача 6 (P2): Гонка перезапуска в updateConnection

**Файлы:** `Sources/SSHManager/Tunnel/TunnelSupervisor.swift:170-186`

**Суть.** `updateConnection` останавливает старый движок (SIGTERM уходит асинхронно) и тут же стартует новый. Старый ssh ещё держит порт `listenPort+10000`, старый ProxyServer — `listenPort` → новый бинд падает; с autoReconnect спасает ретрай через 2 с, без него — сразу `.failed`. Бонус-дефект: если старый был в `.reconnecting`, новый вообще не стартует (`wasRunning` проверяет только `.running`).

**Исправление.** Считать «активным» `.running` ИЛИ `.reconnecting`. Новый движок ставить в `engines`, но стартовать только после того, как старый дойдёт до `.stopped`: переназначить `old.onStateChange` на замыкание, которое (на main) пишет событие в историю, дёргает `objectWillChange`/`onChange` и при `case .stopped` запускает `engines[c.id]?.start()`; если старый уже `.stopped` — стартовать сразу.

---

### Задача 7 (P2): При выходе из приложения история не получает .stopped

**Файлы:** `Sources/SSHManager/AppDelegate.swift:31-33`, `Sources/SSHManager/Tunnel/TunnelSupervisor.swift:157-159`, `Sources/SSHManager/History/HistoryStore.swift`

**Суть.** `applicationWillTerminate → stopAll()` шлёт SIGTERM, но `.stopped`-события пишутся из асинхронного `handleTermination`, который не успевает до выхода процесса. После перезапуска статистика считает туннель «работавшим» весь простой (последнее событие — started).

**Исправление.** Заменить `stopAll()` на `shutdownForQuit()`: для каждого движка в `.running`/`.reconnecting` синхронно записать `history.recordEvent(.stopped)`, затем `e.stop()`, в конце `history?.flush()` (метод `queue.sync {}` из задачи 3). AppDelegate вызывает новый метод; `stopAll` удалить (других вызовов нет).

---

### Задача 8 (P2): Лог соединения обнуляется на каждом старте/ретрае

**Файлы:** `Sources/SSHManager/Tunnel/TunnelEngine.swift:480-484`

**Суть.** `openLogFile()` делает `createFile(atPath:contents:nil)` безусловно — каждый старт, включая каждую попытку реконнекта, стирает лог предыдущей попытки. Диагностировать цикл реконнектов по логу невозможно (а README прямо советует смотреть лог при сбое).

**Исправление.** Создавать файл только если его нет; иначе открывать и `seekToEnd()`. Перед открытием — простая ротация: если файл больше ~1 МБ, удалить его и создать заново.

---

### Задача 9 (P3): StatsView молотит SQLite каждые 0.5 с

**Файлы:** `Sources/SSHManager/UI/StatsView.swift:58-62`

**Суть.** `.onReceive(supervisor.objectWillChange) { reload() }` — supervisor публикуется каждые 0.5 с (поллинг статистики) и на каждом пинг-тике. `reload()` тянет всю выборку диапазона синхронно (`queue.sync`) на main-потоке; для 30d это ~260 тыс. строк каждые полсекунды — подвисания UI.

**Исправление.** Заменить подписку на `objectWillChange` таймером: `.onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in reload() }`. `onAppear`/`onChange(of: range)` оставить.

---

### Задача 10 (P3): Меню статус-бара пересоздаётся каждые 0.5 с

**Файлы:** `Sources/SSHManager/UI/MenuBarController.swift:21,25-81`, `Sources/SSHManager/Tunnel/TunnelSupervisor.swift` (onChange)

**Суть.** `supervisor.onChange → rebuildMenu()` присваивает новый `statusItem.menu` при каждом изменении счётчиков (каждые 0.5 с при трафике), в том числе пока меню открыто — мерцание/глюки трекинга.

**Исправление.** Перейти на `NSMenuDelegate`: создать `NSMenu` один раз, назначить `menu.delegate = self`, наполнять пункты в `menuNeedsUpdate(_:)` (вызывается при каждом открытии). Подписку `supervisor.onChange` из MenuBarController убрать. После этого у `onChange` не останется потребителей — удалить свойство и все его вызовы из TunnelSupervisor (мёртвый код).

---

### Задача 11 (P3): Устаревшие тексты про autoReconnect

**Файлы:** `Sources/SSHManager/UI/ConnectionEditView.swift:70-71`, `README.md:5-18,122,153-156`

**Суть.** Подсказка у тумблера «Auto-reconnect on drop» говорит «Reserved for a later phase. Currently has no effect» — фича давно реализована (backoff 2-60 с, 20 попыток). README описывает только «Phase 1»: в «Not yet» перечислены уже сделанные editor UI, byte counters, auto-reconnect, stats, login item; таблица полей называет `autoReconnect` «ignored in phase 1».

**Исправление.** Заменить help-текст на описание реального поведения (например: «Reconnect with backoff (2s–60s), up to 20 attempts»). В README: убрать/переписать секцию Status, поправить строку таблицы про `autoReconnect`, абзац «phase 5 will add automatic reconnection» и упомянуть HTTP-прокси для dynamic-туннелей.

---

### Задача 12 (P3): Сэмплы пишутся для остановленных соединений

**Файлы:** `Sources/SSHManager/Tunnel/TunnelSupervisor.swift:62-81`

**Суть.** `writeHistorySamples` на каждом пинг-тике (10 с) пишет строку в SQLite для КАЖДОГО соединения, включая остановленные (нулевые дельты + пинг) — ~8.6 тыс. мусорных строк/сутки на соединение.

**Исправление.** В начале цикла: `guard let engine = engines[c.id], engine.state.isRunning else { continue }`. Пропуски в графиках для остановленных периодов — корректное отражение реальности (state-band и так показывает периоды по событиям).

---

### Задача 13 (P4): Мёртвое поле PingResult.updatedAt

**Файлы:** `Sources/SSHManager/Tunnel/PingMonitor.swift:7,72,93`

**Суть.** Поле записывается, но нигде не читается.

**Исправление.** Удалить поле и оба места инициализации (`PingResult(rttMs: x)`).

---

### Задача 14 (P4): Окно статистики живёт после удаления соединения

**Файлы:** `Sources/SSHManager/UI/ConnectionListView.swift:180-186`

**Суть.** Если открыт stats-sheet и соединение удалено (например, из другого пути), sheet остаётся со стейлом.

**Исправление.** В обработчике `onDelete` перед `deleteConnection`: `if statsFor?.id == c.id { statsFor = nil }`.

---

### Задача 15 (P4): HTTP CONNECT теряет early-data клиента

**Файлы:** `Sources/SSHManager/Tunnel/HttpProxyServer.swift:65-94,266-276`

**Суть.** `readHttpRequest` находит `\r\n\r\n` и передаёт дальше только заголовки; байты, пришедшие в том же пакете после заголовков (TLS ClientHello сразу за CONNECT), отбрасываются — такие соединения зависают.

**Исправление.** Вырезать `leftover = buf[endRange.upperBound...]`, протащить через `handleRequest`/`connectViaSocks`/`socksHandshake`/`socksConnect` до `completeHandshakeAndSplice` и там, если не пуст, отправить в socks до запуска `splice`.

---

### Задача 16 (P4): ProxyServer не закрывает соединения после чистого завершения

**Файлы:** `Sources/SSHManager/Tunnel/ProxyServer.swift:95-124` (аналогично `HttpProxyServer.splice`)

**Суть.** При `isComplete` pump шлёт half-close и выходит; если обе стороны завершились чисто (без error), `cancel()` не вызывается ни разу — пара NWConnection живёт до конца работы движка. Медленная утечка на долгоживущих туннелях.

**Исправление.** На пару соединений завести счётчик завершённых направлений (маленький класс-холдер, доступ только на `queue`); при `isComplete` инкрементировать, при достижении 2 — `cancel()` обеим сторонам (после completion финального send).

---

### Задача 17 (P4): HTTP-порт может совпасть с внутренним ssh-портом

**Файлы:** `Sources/SSHManager/UI/ConnectionEditView.swift:132-142`

**Суть.** Валидация запрещает HTTP-порту равняться `listenPort`, но не `listenPort + 10000` (порт, который занимает сам ssh `-D`).

**Исправление.** Добавить проверку `p == draft.listenPort + 10000` → «HTTP port conflicts with the internal ssh port (listen port + 10000)».

---

## Порядок выполнения и зависимости

1. Задача 0 (тестовый таргет) — первой, её требуют задачи 3 и 5.
2. Задачи 1-4 (P1) — в любом порядке; задача 4 частично пересекается с 5 (конверсии портов) — делать 4 раньше 5.
3. Задачи 5-8 (P2), затем 9-12 (P3), затем 13-17 (P4) — независимы друг от друга, кроме: задача 7 использует `flush()` из задачи 3; задача 10 удаляет `onChange`, поэтому выполняется после всех задач, трогающих TunnelSupervisor (6, 7, 12).
4. После каждой задачи: `swift build && swift test`, коммит с сообщением из задачи (для компактных задач — `fix:`/`chore:` + краткая суть).
5. Финальная проверка: `./scripts/build-app.sh`, прогнать вручную сценарии — старт/стоп рабочего туннеля, реконнект на несуществующем хосте + «Stop» во время реконнекта, статистика после обрывов, `netstat` на loopback-бинд.
