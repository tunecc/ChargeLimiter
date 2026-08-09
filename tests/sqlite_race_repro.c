// sqlite_race_repro.c
// ---------------------------------------------------------------------------
// Minimal reproduction test for ChargeLimiterDaemon crash:
//   http 并发队列 get_statistics -> getDBData() 时 sqlite3_step 崩，
//   故障地址 0x61746164 == ASCII "data"（小端），即被释放/复用的内存残留字符串。
//
// 根因（见分析）：
//   daemon.mm 里 `static sqlite3* db` 全局句柄被多个线程无锁共用：
//     - http CONCURRENT 队列: getDBData / getPolicyEventDBData (读)
//     - reload_conf / app_docs 切换: uninitDB()+initDB() 热关重开
//     - battery 事件(主线程): insertPolicyEventDBData / updateDBData (写)
//   系统 libsqlite3 编译为 THREADSAFE=2（multi-thread），同一连接跨线程并发
//   本身就是数据竞争；再叠加 close/reopen 窗口就是 use-after-free。
//
// 本文件把 daemon 的 sqlite 函数用纯 C 1:1 镜像，用多线程压出失败：
//   -DUSE_LOCK=0   无锁（当前 daemon 行为）       -> 应触发 crash / TSan / ASan 报告
//   -DUSE_LOCK=1   每次 sqlite 调用加同一把锁      -> 应干净运行（修复目标）
// 注：真机 daemon 的修复用的是 递归 锁（PTHREAD_MUTEX_RECURSIVE），因为
//   insertPolicyEventDBData->prune / migrate->insert / clearAll->clearForBattery
//   存在嵌套调用；本 test 的调用没有嵌套，用普通互斥锁即可表达同一串行化不变量。
// 构建/运行见 run_repro.sh
// ---------------------------------------------------------------------------
#define _POSIX_C_SOURCE 200809L
#include <sqlite3.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

static const char *g_dbPath = "/tmp/chargelimiter_race_repro.db";
static sqlite3 *db = NULL; // 镜像 daemon.mm:2261 的全局句柄

#ifdef USE_LOCK
static pthread_mutex_t g_dbLock = PTHREAD_MUTEX_INITIALIZER;
#define DB_LOCK()   pthread_mutex_lock(&g_dbLock)
#define DB_UNLOCK() pthread_mutex_unlock(&g_dbLock)
#else
#define DB_LOCK()   do {} while (0)
#define DB_UNLOCK() do {} while (0)
#endif

// ---- 镜像 daemon.mm initDB() -------------------------------------------
static void initDB(void) {
    DB_LOCK();
    if (!db) {
        sqlite3 *cdb = NULL;
        if (sqlite3_open(g_dbPath, &cdb) != SQLITE_OK) {
            fprintf(stderr, "[initDB] open failed: %s\n", sqlite3_errmsg(cdb));
            exit(2);
        }
        db = cdb;
    }
    if (db) {
        char *err = NULL;
        sqlite3_exec(db,
            "create table if not exists policy_events "
            "(id integer primary key autoincrement, ts integer not null, "
            "type text not null, data text not null)", NULL, NULL, &err);
        if (err) { sqlite3_free(err); err = NULL; }
        sqlite3_exec(db,
            "create table if not exists min5 (id integer primary key, data text)",
            NULL, NULL, &err);
        if (err) { sqlite3_free(err); err = NULL; }
        sqlite3_exec(db,
            "create table if not exists hour (id integer primary key, data text)",
            NULL, NULL, &err);
        if (err) { sqlite3_free(err); err = NULL; }
    }
    DB_UNLOCK();
}

// ---- 镜像 daemon.mm uninitDB() -----------------------------------------
static void uninitDB(void) {
    DB_LOCK();
    if (db != NULL) {
        int rc = sqlite3_close(db);
        if (rc != SQLITE_OK) {
            sqlite3_close_v2(db); // 有未 finalize stmt 时延迟关闭
        }
        db = NULL;
    }
    DB_UNLOCK();
}

// ---- 镜像 daemon.mm getDBData(tbl, n, last_id) -------------------------
static int getDBData(const char *tbl, int n, int last_id) {
    int rows = 0;
    DB_LOCK();
    if (!db) { DB_UNLOCK(); return 0; }
    if (n < 1) n = 1;
    if (n > 1000) n = 1000;
    char sql[256];
    snprintf(sql, sizeof(sql),
             "select data from %s where id > %d order by id desc limit %d",
             tbl, last_id, n);
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK || stmt == NULL) {
        DB_UNLOCK();
        return 0;
    }
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *jstr = (const char *)sqlite3_column_text(stmt, 0);
        if (jstr == NULL) continue;
        (void)strlen(jstr); // 镜像: [NSData dataWithBytes:length:strlen(jstr)]
        rows++;
    }
    sqlite3_finalize(stmt);
    DB_UNLOCK();
    return rows;
}

// ---- 镜像 daemon.mm getPolicyEventDBData(n, last_id) -------------------
static int getPolicyEventDBData(int n, int last_id) {
    int rows = 0;
    DB_LOCK();
    if (!db) { DB_UNLOCK(); return 0; }
    if (n < 1) n = 1;
    if (n > 200) n = 200;
    char sql[256];
    snprintf(sql, sizeof(sql),
             "select id, ts, type, data from policy_events "
             "where id > %d order by id desc limit %d", last_id, n);
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK || stmt == NULL) {
        DB_UNLOCK();
        return 0;
    }
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        (void)sqlite3_column_int(stmt, 0);
        (void)sqlite3_column_int64(stmt, 1);
        const char *typeText = (const char *)sqlite3_column_text(stmt, 2);
        const char *jstr = (const char *)sqlite3_column_text(stmt, 3);
        if (jstr) (void)strlen(jstr);
        if (typeText) (void)strlen(typeText);
        rows++;
    }
    sqlite3_finalize(stmt);
    DB_UNLOCK();
    return rows;
}

// ---- 镜像 daemon.mm insertPolicyEventDBData + updateDBData（写） -------
static void insertPolicyEvent(void) {
    DB_LOCK();
    if (!db) { DB_UNLOCK(); return; }
    const char *sql = "insert into policy_events (ts, type, data) values(?1, ?2, ?3)";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK || stmt == NULL) {
        DB_UNLOCK();
        return;
    }
    char json[128];
    snprintf(json, sizeof(json),
             "{\"data\":{\"v\":%d,\"ts\":%ld},\"type\":\"policy_transition\"}",
             rand() % 1000, (long)time(NULL));
    sqlite3_bind_int64(stmt, 1, (sqlite3_int64)time(NULL));
    sqlite3_bind_text(stmt, 2, "policy_transition", -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 3, json, -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    DB_UNLOCK();
}

static void writeStats(void) {
    DB_LOCK();
    if (!db) { DB_UNLOCK(); return; }
    const char *sql = "insert or ignore into min5 values(?1, ?2)";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK || stmt == NULL) {
        DB_UNLOCK();
        return;
    }
    int tid = (int)(time(NULL) / 300);
    char json[128];
    snprintf(json, sizeof(json),
             "{\"data\":{\"cap\":%d,\"amp\":%d},\"UpdateTime\":%ld}",
             rand() % 100, rand() % 1000, (long)time(NULL));
    sqlite3_bind_int(stmt, 1, tid);
    sqlite3_bind_text(stmt, 2, json, -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    DB_UNLOCK();
}

// ---- 线程：读（镜像 http get_statistics / get_bat_info） ----------------
enum { NUM_READERS = 4, NUM_WRITERS = 2, NUM_RELOADS = 1 };
static int g_iterations = 20000;

static void *readerThread(void *arg) {
    long id = (long)arg;
    for (int i = 0; i < g_iterations; i++) {
        getPolicyEventDBData(200, 0);
        getDBData("min5", 50, 0);
        getDBData("hour", 50, 0);
    }
    printf("[reader %ld] done\n", id);
    return NULL;
}

static void *writerThread(void *arg) {
    long id = (long)arg;
    for (int i = 0; i < g_iterations / 2; i++) {
        insertPolicyEvent(); // 镜像主线程 battery 事件
        writeStats();
    }
    printf("[writer %ld] done\n", id);
    return NULL;
}

static void *reloadThread(void *arg) {
    long id = (long)arg;
    for (int i = 0; i < g_iterations / 10; i++) {
        uninitDB(); // 镜像 reload_conf: uninitDB()+initDB(nil)
        initDB();
    }
    printf("[reload %ld] done\n", id);
    return NULL;
}

// -------------------------------------------------------------------------
int main(int argc, char **argv) {
    if (argc > 1) g_iterations = atoi(argv[1]);
    if (g_iterations < 1) g_iterations = 1;

    unlink(g_dbPath);
    initDB();
    for (int i = 0; i < 50; i++) { // 预置行，让读线程有数据可迭代
        insertPolicyEvent();
        writeStats();
    }

    int total = NUM_READERS + NUM_WRITERS + NUM_RELOADS;
    pthread_t th[total];
    int t = 0;
    for (int i = 0; i < NUM_READERS; i++)  pthread_create(&th[t++], NULL, readerThread, (void *)(long)i);
    for (int i = 0; i < NUM_WRITERS; i++)  pthread_create(&th[t++], NULL, writerThread, (void *)(long)i);
    for (int i = 0; i < NUM_RELOADS; i++)  pthread_create(&th[t++], NULL, reloadThread, (void *)(long)i);

    for (int i = 0; i < total; i++) pthread_join(th[i], NULL);

    printf("RAN_COMPLETE_%s\n",
#ifdef USE_LOCK
           "LOCKED"
#else
           "NOLOCK"
#endif
           );
    return 0;
}
