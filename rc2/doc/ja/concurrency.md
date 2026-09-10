# 並行性(`rc2/support/rc2/`)

(原文: `doc/concurrency.md`。内容が乖離した場合は原文を正とする。
これは *living document* であり、後続ステージが着地するたびに原文が
更新される。)

rc2 のランタイム側の並行性方針の実装ノート。段階的に構築された:
まず参照カウント自体を複数スレッドから触っても安全にし、次に実際の
OS スレッド生成(`refc_fork`)と Mutex/Condition を実際に動かし、
次にその第 2 段階で除外された残りすべての `System.Concurrency` 系
プリミティブ(`conditionWaitTimeout`、`getThreadId`、
`setThreadData`/`getThreadData`、`Semaphore`、`Barrier`、`Channel`)
に加えて rc2 固有の join 可能な fork を埋めた -- 3 段階すべて完了。
何が実装済みかの正確な内容は下記 "ステータス" を参照。この文書全体
で本当に新しい Idris レベルの API 面を追加するのは 1 つだけ: rc2
固有の join 可能な fork(`forkJoin`/`join`/`JoinHandle`)。これは
パッチを当てる上流の相当物がない -- 理由は下記
"設計: join 可能な fork" を参照。それ以外はすべて、`Channel`
(その往復は "設計: Channel" を参照)を含めて、`%foreign_impl` 経由
で既存の上流 `System.Concurrency` 宣言にパッチを当てる: 既存の型と
関数は無変更で動作し、ただスタブではなく実スレッドと pthread
プリミティブで実際に裏打ちされるようになる。将来のセッション
(あるいは将来の自分)が設計を再導出したり、ここで既に特定した
制約を再発見したりせずに完全な文脈を取り戻せるよう書かれている。

## 背景

rc2 のランタイム(`rc2/support/rc2/`)は上流 RefC 自身のサポート
ライブラリの末裔であり、それは全体を通してシングルスレッド実行
モデルを仮定する: 参照カウントは素の非アトミック整数で、通常の
`++`/`--` で変更される。rc2 は歴史の大半でその仮定を無変更で
継承した(`TODO.md` の旧 "Concurrency: unchanged from RefC"
エントリ、現在はこの文書に置き換えられた)。

rc2 の歴史の大半、そして下記のアトミック refcount ステップを
通じても真だったが、rc2 の中で実際の OS スレッドを生成するものは
何もなかった: `%foreign "C:refc_fork"`(`rc2/support/rc2/ioprims.c`、
Idris2 の `prim__fork` の着地点)は "Threads not implemented in the
rc2 backend!" を印字して実際にスレッドを fork せず `exit(0)` を
呼ぶスタブだった。それが実スレッド生成ステップで変わった(下記
"設計: 実スレッド生成" を参照)-- `refc_fork` は今や実際に detach
された `pthread` を生成するので、参照カウントの変更がスレッド間で
本当にレースし得る。まさにそれを、下記のアトミック表現と
"実スレッド生成が解き放ったレースの解決" の修正が安全にするために
存在する。

refcount を先にアトミックにし、`refc_fork` が実際に何かをする前に
そうしたのは意図的な地ならしだった: どのコードもそれが正しいこと
に依存する前に*表現*を正しくでき、後の実スレッド生成ステップを
精密にスコープが切られた追随作業に変えた -- そのステップに対する
この文書自身の課題リスト(3 つの素のデクリメントと小整数の遅延
初期化フラグ、下記参照)が、時間的プレッシャーの下で行う 2 回目の
よりリスクの高いリバースエンジニアリングパスではなく、次のステップ
が加えるべき差分そのものになった。

## 設計: アトミック refcount、そしてなぜこれらのメモリオーダーか

このステップで変更したファイル: `datatypes.h`、`memory.c`、
`runtime.h`。`memory.h`/`runtime.c` はここでは無変更だった(当時
それが安全だった理由と、実スレッド生成が着地して何が変わったかは
下記 "実スレッド生成が解き放ったレースの解決" を参照)。

- **`datatypes.h`**: `IDRIS2RC2_Header.refCount` を `uint16_t` から
  `_Atomic uint16_t` に変更(`<stdatomic.h>` を include 追加)。
  "非アトミックな参照カウント" と記述していたヘッダ自身のファイル
  冒頭コメントも一致するよう更新。
- **`memory.c`、`idris2rc2_dup`**: インクリメントは今
  `atomic_fetch_add_explicit(&v->header.refCount, 1,
  memory_order_relaxed)`。ここで `relaxed` で十分なのは、既に生きて
  いると分かっているカウント(呼び出し側は既に参照を保持)を
  インクリメントするのは他のメモリを公開・観測する必要がないから
  である -- すべての先行リーダーと同期しなければならないのは
  *ゼロに達するデクリメント*であって、インクリメントではない。
- **`memory.c`、`idris2rc2_drop`**: デクリメントは今
  `atomic_fetch_sub_explicit(&v->header.refCount, 1,
  memory_order_release)`。その戻り値(デクリメント*前*のカウント)
  が `1` か検査され、そのときだけ `idris2rc2_teardown` を呼ぶ直前に
  `atomic_thread_fence(memory_order_acquire)` が走る。これは標準的な
  release デクリメント + ゼロ時 acquire フェンスパターンである:
  すべてのデクリメントの `release` は、各スレッド自身のポインタ先へ
  の先行書き込み(と自身の参照の drop)が*最後の*デクリメントを
  行うスレッドから見えることを保証する; カウントがゼロに達したのを
  実際に観測したスレッドでのみ支払われる `acquire` フェンスは、その
  スレッドが値の取り壊しを始める前に他のすべてのスレッドの release
  を見ることを保証する。すべての drop で無条件に acquire フェンスを
  支払っても(teardown 経路のみでなく)正しいが、圧倒的に一般的な
  非最終 drop のケースで無用に高価である。
  デクリメントの真上の不滅チェック
  (`refCount == IDRIS2RC2_REFCOUNT_MAX`)は素の非アトミック比較の
  ままにしてある -- 不滅状態に達した値はそれ以降 `refCount` を何に
  よっても書き込まれない(`idris2rc2_dup` 自身の
  `!= IDRIS2RC2_REFCOUNT_MAX` ガードと `idris2rc2_getSmallInteger`
  の小整数キャッシュ初期化を参照)ので、そのフィールドの並行
  リーダーがレースする書き込みが存在しないため安全である。
- **`runtime.h`、`idris2rc2_isUnique`**: 今
  `atomic_load_explicit(&(x)->header.refCount, memory_order_acquire)
  == 1`。`acquire` は単なる利便ではなく必須である: `refCount == 1`
  の観測こそがインプレース変更(コンストラクタ再利用などが依存する
  「このスレッドが証明可能に唯一の所有者」論法)を許可するので、
  その観測は、カウントを最近 1 まで下げた他のいずれかのスレッドの
  `release` デクリメントの後で起きなければならない -- そうでないと、
  最後に知られた共有状態がまだ伝播し終わっていない値をこのスレッド
  が変更し始め得る。`IDRIS2RC2_Header header` フィールドで始まる
  *任意の*構造体型に対して汎用のままであるよう(各呼び出し箇所
  自身の具体的なポインタ型、例えば `IDRIS2RC2_Constructor *` に
  合わせて)、型付き `static inline` 関数ではなく意図的にマクロの
  ままにしてある。この変更前からマクロが持っていた理由と同じ。

## 設計: 実スレッド生成(`refc_fork`)

変更したファイル: `ioprims.c`(`util.h` と `<pthread.h>` を
include 追加)。

`refc_fork` は今、fork されたクロージャを実際の detach された
`pthread` 上で走らせる:

- `pthread_create` を呼ぶ前にクロージャを `idris2rc2_dup` し、dup
  したポインタを小さなトランポリン(`idris2rc2_threadTrampoline`)
  に渡す。それは `idris2rc2_applyClosure` 経由で消去された `%World`
  トークンに適用し、結果を drop する。この dup は任意の帳簿付けでは
  ない -- このステップのテスト中に見つかった本物の use-after-free を
  修正する: 生成された `prim__fork` ラッパは `refc_fork` が返った
  直後にクロージャへの自身の参照を drop する(通常の「FFI 呼び出し
  は引数を消費した」規約)が、生成されたスレッドはその時点をずっと
  過ぎても同じポインタを使い続ける。dup がないと、呼び出し側の drop
  がまだ走っているスレッドの下からクロージャを解放し得る。
- スレッドは即座に `pthread_detach` され、join されない。これは
  実際に到達可能なものに一致する: fork されたスレッドを join でき
  る唯一の Idris レベルプリミティブ `threadWait` は、上流
  `System.Concurrency.idr` で Scheme のみであり C バックエンド実装
  が一切ない -- `refc_fork` 自体が何をしようと rc2(や RefC)から
  到達不能。fire-and-forget な detach スレッドはしたがって
  ショートカットではない; 現在どの呼び出し側も観測できる唯一の
  振る舞いである。
- 返される `ThreadID` は、専用タグではなく、ヒープ割り当てされた
  `pthread_t` を包む素の `IDRIS2RC2_Pointer` である。`ThreadID` は
  上流 Idris2 で `[external]` であり、rc2 はそれを CFUser として
  marshal する(制約のない `IDRIS2RC2_Value*` の恒等パススルー --
  `Compiler.RC2.Emit.Util` の `packCFType`/`extractValue` を参照)
  ので、正しい形状の値なら何でも動く; `threadWait` がそれを決して
  読めない(上記参照)ので、専用の表現を必要とするものはない。

## 実スレッド生成が解き放ったレースの解決

`refc_fork` が本物になった(上記)ことは、ついに 2 つ以上の
スレッドが並行に走れることを意味し、`runtime.c` の 3 つの呼び出し
箇所と `memory.c` の 1 つを初めて到達可能なレースにした。4 つとも
今は修正済み; このセクションは、このステップの前になぜ各々が安全
だったかの元の論理を保持し、何が変わったかを記録する。

**`idris2rc2_trampoline`、`idris2rc2_tailcallApplyClosure`、
`idris2rc2_dropReuseConstructor`(`runtime.c`)。** このステップの
前、3 つとも `refCount` に対してゼロ到達チェックを一切せずに素の
`--`/`==` を行っていた。これはそのままコンパイル・実行して正しく
動いた -- `refCount` が `_Atomic uint16_t` になった今、それに対する
素の `--`/`==` は C11 の暗黙のアトミック複合代入/比較(デフォルト
`memory_order_seq_cst`)なので、型エラーも未定義動作もなかった --
が、**シングルスレッド実行不変条件**に依存していた: 各々は
「非一意」ブランチでのみ走り、そこでは `annotate` 自身の所有権
解析が入る時点でカウントが少なくとも 2 だと既に確立していたので、
素のデクリメントがそこでゼロに達し得なかった。これは同じ値を同時
に他の何かが並行に drop できないからこそ真だった。以下のように
修正:

- `idris2rc2_trampoline`: `isUnique(c) ? free(c) : --c->header.refCount`
  ブランチは今、単一の無条件
  `atomic_fetch_sub_explicit(..., memory_order_release)` であり、
  それが `1` を返したときだけ `c` を解放する(まず
  `atomic_thread_fence(memory_order_acquire)` でガード)-- 
  `idris2rc2_drop` が既に使っていた release デクリメント + ゼロ時
  acquire フェンスと同じパターン。`dispatchClosure` が既に引数の
  所有権を消費していたので、ここで解放されるのはクロージャの殻
  自体だけであり、完全な `idris2rc2_drop` 取り壊しではない; 引数を
  再 drop すると二重 drop になる。
- `idris2rc2_tailcallApplyClosure`: その引数は新しいクロージャへ
  盗まれるのではなく `dup` されるので、`c` 自身の参照は通常通り
  release される -- 素の `--c->header.refCount;` は通常の
  `idris2rc2_drop((IDRIS2RC2_Value *)c)` 呼び出しに置き換えられた。
- `idris2rc2_dropReuseConstructor`: `idris2rc2_trampoline` と同じ
  release デクリメント + ゼロ時 acquire フェンスへの入れ替え。
  ただしここでは本物のレース修正というより念のためである -- この
  関数は `idris2rc2_isUnique` が既に静的に一意性を確立した値に
  対してのみ呼ばれる(`reuse-analysis.md` を参照)ので、いずれに
  せよ他のスレッドがこの特定の `refCount` を並行に触れない;
  変更は、素のアクセスがたまたま安全である別途の論拠に頼るのでは
  なく、メモリアクセスを他のすべての `refCount` 操作のように
  アトミックにするだけである。

`runtime.h` が `idris2rc2_isUnique` の真上に直接持っていた、この
制約を記録する 1 行の "Why not" コメントは、もはや当てはまらない
ので除去された。

**`idris2rc2_getSmallInteger` の遅延初期化フラグ(`memory.c`)。**
このステップの前、`idris2rc2_smallIntegerInit` は素の非アトミック
`static bool` で、古典的な非同期の check-then-set-then-init-loop を
駆動していた -- 2 つのスレッドが決して並行に呼べないからこそ安全
であり、実際に並行な初回呼び出しの下では初期化ループが 2 回以上
走ったり、あるスレッドが部分的に初期化されたキャッシュを観測したり
し得た。フラグを `pthread_once` で駆動される
`pthread_once_t` / `idris2rc2_initSmallInteger` の組に置き換えて
修正。これは初期化ループがちょうど 1 回走ること、そしてどの
呼び出し側もスレッドを問わずキャッシュが完全に初期化された状態
しか観測しないことを保証する。

## 設計: Mutex/Condition

上流 Idris2 の `System.Concurrency` モジュールは `Mutex`、
`Condition`、`makeMutex`、`mutexAcquire`、`mutexRelease`、
`makeCondition`、`conditionWait`、`conditionSignal`、
`conditionBroadcast` を `%foreign` プリミティブとして宣言するが、
Scheme バックエンド実装しか出荷しない -- RefC を含むすべての C
バックエンドは、これらを一度も使えたことがない。

実装したものに落ち着く前に、2 つの代替設計が検討された:

- **pthread オブジェクトを `GCAnyPtr` で包む**(rc2 の既存の
  任意ペイロード + ファイナライザのポインタ型)。却下: `GCAnyPtr`
  はファイナライザを通常の `PrimIO ()` クロージャ適用経路で走らせる
  -- つまり取り壊しごとに完全なクロージャ適用のコストがかかる --
  固定の事前既知の C デストラクタ呼び出ししか必要としない
  ペイロード(`pthread_mutex_t`/`pthread_cond_t`)に対して。
- **既存の `Mutex`/`Condition` を裏打ちするのではなく、Idris 側に
  独自の FFI 面を持つ新しい `data` 型を導入する**。却下: すべての
  呼び出し側に `System.Concurrency` ではなく rc2 固有のモジュール
  への依存を強制し、何の利益もなく上流 API に対して書かれた
  コードの移植性を壊す -- `Mutex`/`Condition` の既存シグネチャに
  変更が必要なものは何もなかった。

代わりに実装したもの:

- **`%foreign_impl`**
  (`libs/rc2base/src/System/Concurrency/RC2.idr`)、既存の Idris2
  ディレクティブ(`idris2-src/docs/source/ffi/ffi.rst` を参照)で、
  別モジュールの*既存の*プリミティブ宣言に、そのモジュールに触れ
  ずに具体的な `%foreign` 実装を付ける(`idris2-src` は読み取り
  専用の上流クローンで、決して編集しない)。呼び出し側は通常の
  `System.Concurrency` と並んで `System.Concurrency.RC2` の import
  を 1 つ追加する -- `Mutex`、`Condition`、`makeMutex`、その他の
  上流 API はそこから完全に無変更で動作する; 新しい型や関数は
  どこにも導入されない。
- **2 つの新しいネイティブ `IDRIS2RC2_Value` タグ**、
  `IDRIS2RC2_TAG_MUTEX`/`IDRIS2RC2_TAG_CONDITION`(`datatypes.h`)、
  各々ヘッダ前置きの値に `pthread_mutex_t`/`pthread_cond_t` を
  直接埋め込んだ単一割り当て構造体(余分なポインタ間接なし)。
  これは上流の `Mutex`/`Condition` が `[external]` と宣言されている
  ことが許可するものである: rc2 は `[external]` を CFUser として
  marshal する(制約のない `IDRIS2RC2_Value*` の恒等パススルー、
  `Compiler.RC2.Emit.Util` の `packCFType`/`extractValue` を参照)
  ので、正しくタグ付けされた値なら何でも有効 -- pthread
  オブジェクトをインラインに持つ専用タグはそれを満たす最も単純な
  形状であり、`idris2rc2_teardown`(`memory.c`)が refcount がゼロ
  に達したら自動的に
  `pthread_mutex_destroy`/`pthread_cond_destroy` を呼べる。
  `IDRIS2RC2_TAG_BUFFER` が既にそのバッファを解放するのと同じ
  やり方 -- Idris 側に明示的な `free` プリミティブは不要。
- 実際の `pthread_mutex_*`/`pthread_cond_*` 呼び出しは
  `libs/rc2base/support/c/concurrency_util.c` にあり、
  `%foreign_impl` の対象として接続される(`idris2rc2_mutex_make`、
  `idris2rc2_mutex_acquire`、`idris2rc2_mutex_release`、
  `idris2rc2_condition_make`、`idris2rc2_condition_wait`、
  `idris2rc2_condition_signal`、`idris2rc2_condition_broadcast`)。

## 設計: Semaphore と Barrier

上の Mutex/Condition と同じパターン、同じ理由: 上流
`System.Concurrency` は
`Semaphore`/`makeSemaphore`/`semaphorePost`/`semaphoreWait` と
`Barrier`/`makeBarrier`/`barrierWait` を Scheme 実装しかない
`%foreign` プリミティブとして宣言する。`%foreign_impl`
(`libs/rc2base/src/System/Concurrency/RC2.idr`)がそれらの既存宣言
に、上流に触れずに C 実装を付ける。2 つの新しいネイティブタグ
`IDRIS2RC2_TAG_SEMAPHORE`/`IDRIS2RC2_TAG_BARRIER`(`datatypes.h`)
は、`IDRIS2RC2_TAG_MUTEX`/`_CONDITION` が既に使う単一割り当て形状
と同じく、`sem_t`/`pthread_barrier_t` をヘッダ前置きの値に直接
埋め込む; `idris2rc2_teardown`(`memory.c`)は refcount がゼロに
達したら `sem_destroy`/`pthread_barrier_destroy` を呼ぶので、
Idris 側に明示的な free プリミティブはない。実際の pthread/semaphore
呼び出し(`idris2rc2_semaphore_make`/`_post`/`_wait`、
`idris2rc2_barrier_make`/`_wait`)は
`libs/rc2base/support/c/concurrency_util.c` にある。

`conditionWaitTimeout` と `getThreadId` も `%foreign_impl` パッチ
だが、新しいタグは不要: `idris2rc2_condition_wait_timeout` は
呼び出し側のマイクロ秒カウントから計算された `CLOCK_REALTIME`
ベースの絶対デッドラインに対して `pthread_cond_timedwait` を包む;
`idris2rc2_get_thread_id` は Linux の `gettid()` を包む
(`_GNU_SOURCE` が必要)。

`setThreadData`/`getThreadData` は単一の
`_Thread_local IDRIS2RC2_Value *`(OS スレッドごとに 1 スロット)で
裏打ちされる。`idris2rc2_set_thread_data` は上書き前にスロットの
以前の値を drop する -- 通常の refcount 規律で、新しい機構ではない
-- そして `idris2rc2_get_thread_data` は返す前に `dup` する。
呼び出し側はスレッドローカルスロットが自身の参照を保つ一方で、
自身の新しい参照を受け取るからである。

## 設計: join 可能な fork(`forkJoin`/`join`、`JoinHandle`)

上流 `System.Concurrency.idr` にはパッチを当てる join 可能な
fork の相当物がない: その `ThreadID`/`threadWait` はどの C
バックエンドからも何も join できず、`threadWait` は Scheme のみ
であり、まさに上記 "設計: 実スレッド生成" が `refc_fork` の無条件
detach を正当化するために既に依拠している到達不能性である。よって
`forkJoin`/`join`/`JoinHandle` は `%foreign_impl` パッチではなく
新規の `%foreign` 宣言
(`libs/rc2base/src/System/Concurrency/RC2.idr`)である -- これは
上流に完全に欠けている、本当に新しい Idris レベルの API 面である。

新しいタグ `IDRIS2RC2_TAG_JOINHANDLE`(`datatypes.h`)は、生の
`pthread_t` と `joined : bool` フラグを保持する。
`idris2rc2_fork_join`(`concurrency_util.c`)は `idris2rc2_fork`
自身のトランポリン(`ioprims.c`)を反映する -- 同じ
use-after-free の理由で `pthread_create` の前にクロージャを `dup`
することを含む -- が、まだ join される必要があるかもしれないので
スレッドを detach*せずに*生成する; `idris2rc2_join` は
`pthread_join` して `joined = true` を設定する。

`joined` フラグが、ハンドルが drop され得るどちらの道でも
`idris2rc2_teardown` の `IDRIS2RC2_TAG_JOINHANDLE` ケースを正しく
する: 一度も join されずに drop されたら、teardown はそれを
`pthread_detach` して下のスレッドがゾンビにならないようにする;
*join されていた*なら、teardown は何もしない。`pthread_join` が
既にスレッドを回収し、その `pthread_t` はもはや有効な識別子では
ないからである -- 再び触れる(2 度目の detach または join)のは
未定義動作。`join` はハンドルごとに最大 1 回呼べると記録されて
いる。上流自身の `Mutex`/`Condition` API が既に持つのと同じ、型で
強制される一意性保証の欠如である; その記録以外に呼び出し側が 2 回
呼ぶのを止めるものはない。

## 設計: Channel

Channel はもともと、このステージで `%foreign_impl` 経由でまったく
付けられなかった唯一のプリミティブだった:
`channelGetNonBlocking`/`channelGetWithTimeout` は `Maybe a` を
返し、汎用ランタイム C から任意のコンパイルの `Just` を構築する
のは一般に安全でなく見えた(完全な調査は TODO.md の
"Dropped: unwrapping `Just x` to a bare `x`" エントリを参照)--
`Nothing` の NULL 表現だけが固定のプログラム非依存の規約である。
よって Channel の最初のバージョンは `Maybe` 構築を完全に避け、
既に検証済みの Mutex/Condition/IORef プリミティブの上に通常の
Idris(`MkChannel (IORef (List a)) Mutex Condition`)で実装され、
上流のを `%hide` で影にする独自の新しい `Channel` 型を持っていた。

それはその後見直され、`%foreign_impl` 裏打ちの実装に置き換えられ、
この文書の他のすべてのプリミティブと同じやり方で
`System.Concurrency` 自身の
`prim__makeChannel`/`prim__channelGet`/`prim__channelGetNonBlocking`/
`prim__channelGetWithTimeout`/`prim__channelPut` にパッチを当てる。
これは TODO.md が不健全として却下と記録する一般的な
「`Just x` を `x` に unwrap する」アイデアでは**ない** -- そちらは
任意のペイロード型に対する Constructor 割り当てを*省略*しようと
し、ペイロード自体が NULL 表現可能なとき(`Just []`、`Just ()`、
`Just Nothing`、...)は常に `Nothing` と衝突する。
`idris2rc2_channel_get_non_blocking`/`_get_with_timeout`
(`libs/rc2base/support/c/concurrency_util.c`)が代わりに行うのは
より狭く健全である: 常に `Just` のための本物の
`IDRIS2RC2_Constructor` を*構築*する(`idris2rc2_newConstructor(1, 1)`)
か `Nothing` のために `NULL` を返し、決して省略しない。これが動く
のは `Prelude.Maybe` 自身のタグ割り当てが固定のプログラム非依存の
事実だからである(経験的に確認: 通常の `Just x` は
`idris2rc2_newConstructor(1, 1)` にコンパイルされ、`ConstFold`
自身のステージ化された static `Just []` も同じタグ/アリティを
使う)-- **記録された制限**であって一般的な技法ではない: `Prelude.Maybe`
がすべての rc2 プログラムで共有される 1 つの固定のバージョン管理
されたライブラリ型であり、プログラムごとのユーザー定義 ADT では
ないことに依拠し、将来の Idris2 が `Nothing`/`Just` 自身の宣言順を
入れ替えたら壊れる。

`Channel a` は新しいネイティブタグ `IDRIS2RC2_TAG_CHANNEL`
(`datatypes.h`)で裏打ちされる: 所有される `IDRIS2RC2_Value*`
ノードの単方向リンク FIFO キューを守る、埋め込まれた
`pthread_mutex_t`/`pthread_cond_t`。`channelPut` はノードを追加
して signal する(まず値を `idris2rc2_dup` する -- 生成された FFI
ラッパは呼び出しが返った直後にすべての引数への自身の参照を drop
する。`idris2rc2_fork`/`idris2rc2_fork_join` 自身の `dup` が既に
記録するのと同じ規約で、ここのノードは呼び出しより長生きする);
`channelGet` はキューが空の間 condition 変数でブロックし、その後
pop する; 非ブロッキング/タイムアウト版はそれぞれ
pop-or-`NULL` と pop-or-wait-once-or-`NULL` である(タイムアウト版
は以前のバージョンの「単一の wait が全予算をカバーし、正確な
デッドライン追跡はしない」単純さを保つ)。`idris2rc2_teardown` の
CHANNEL ケースは mutex/cond を破棄し、まだキューに残るノードを
歩き、ノードを解放する前に各格納値を drop する -- 保留中で決して
受信されないメッセージとともに drop された channel はそれらを
リークしてはならない。

Channel は今や上流自身の宣言にパッチされているので、以前の
バージョンの `%hide` 回避策とその別個の再利用不可能な `Channel`
型は両方なくなった -- 呼び出し側はただ `import System.Concurrency`
`import System.Concurrency.RC2` して、この文書の他のすべての
プリミティブと同じく、`System.Concurrency` 自身の
`Channel`/`makeChannel`/... を無変更で使う。

## 発見: `%foreign` の型ウィットネスは消去されない

`setThreadData`/`getThreadData`/`forkJoin`/`join` の実装中に発見:
`%foreign` プリミティブの多相型パラメータ -- 暗黙の
`{a : Type}`、あるいは `a` が戻り値型に現れるときに rc2 自身の FFI
規約が供給するウィットネス -- は rc2 のコード生成によって消去され
**ない**。経験的に、コンパイラの消去ロジックを直接検査するのでは
なく、実際の生成 C を構築して読むことで確認。影響を受ける 4 つの
C 関数(`idris2rc2_set_thread_data`、`idris2rc2_get_thread_data`、
`idris2rc2_fork_join`、`idris2rc2_join`、`concurrency_util.c`/`.h`)
はしたがって、受け取って即座に無視される先頭の
`IDRIS2RC2_Value *typeWitness` パラメータを取る。素の多相 `a` に
言及するシグネチャを持つ将来のプリミティブで消去を仮定する前に、
第一原理からその仮定を信じるのではなく、これについて生成 C を再度
確認する価値がある。

## ステータス

**参照カウントのアトミック化: 完了・検証済み。** 上記の通り
`datatypes.h`、`memory.c`、`runtime.h`。`rc2/tests/verify.sh`
(refc-suite 19/19 PASS、スモークテスト 32/32 PASS、`valgrind`
エラー 0)と `rc2/tests/bench.sh`(上記 `relaxed`/`release`/`acquire`
の選択による測定可能な性能回帰なし)で検証; `-Wall` ビルド
クリーン。

**実スレッド生成(`refc_fork`)と Mutex/Condition: 完了・検証済み。**
`refc_fork` は今や実際の detach された `pthread` を生成する(上記
"設計: 実スレッド生成")。これがアトミック refcount ステップで
フラグ立てされた 4 つのレースすべてを初めて到達可能にした --
4 つとも今は修正済み(上記 "実スレッド生成が解き放ったレースの
解決")。`Mutex`/`Condition` は `System.Concurrency.RC2` の
`%foreign_impl` 経由で rc2 から使える(上記 "設計: Mutex/Condition")。
`rc2/tests/verify.sh`(refc-suite 19/19 PASS、スモークテスト
32/32 PASS、`valgrind` エラー 0)と `libs/rc2base/tests/verify.sh`
(`TestText`/`TestTextTree`/`TestConcurrency` すべて PASS -- 新しい
`TestConcurrency.idr` は `fork` + `Mutex` + `Condition` を一緒に
行使する: 複数スレッドが共有カウンタをインクリメントし condition
を待つ)、加えて `valgrind --fair-sched=yes` と `helgrind` が
データレースなしを報告、`rc2/tests/bench.sh` が測定可能な性能回帰
なしを示す、で検証。

**残りの `System.Concurrency` 系プリミティブ、join 可能な fork、
Channel: 完了・検証済み。** `conditionWaitTimeout`、`getThreadId`、
`setThreadData`/`getThreadData`、`Semaphore`、`Barrier`、そして
(後の見直しとして、上記 "設計: Channel")`Channel` 自体は、
`Mutex`/`Condition` と同じやり方で rc2 から使える -- 上流の既存の
prim__ 宣言への `%foreign_impl`。rc2 固有の join 可能な fork
(`forkJoin`/`join`/`JoinHandle`)は、上流自身がどの C バックエンド
でもカバーできない 1 つのギャップを埋める(上記 "設計: join
可能な fork")。`rc2/tests/verify.sh`(56 passed、2 known
pre-existing、0 failed)と `libs/rc2base/tests/verify.sh`
(`TestConcurrency.idr` はすべての新しいプリミティブを行使するよう
拡張、すべて PASS)、加えて `valgrind --fair-sched=yes` と
`helgrind` が当時新しいエラーなしを報告、で検証。この段落の以前の
版で言及された 2 つの未解決点は今は解決済み:
`List.(++)`-on-repeated-`IORef`-append リークは
`Compiler.RC2.RC` 自身の `RExtPrim` 所有権注釈ギャップと根本原因を
共有すると判明し(修正済み、`doc/c-struct-support.md` 自身の
補遺を参照)、`idris2rc2_fork` 自身の `ThreadID` malloc(ヒープ
割り当てされた `pthread_t*` を汎用 `IDRIS2RC2_Pointer` で包み、
その teardown は外部所有ペイロードを意図的に決して解放しない --
rc2 自身が割り当てたポインタには誤り)は、`Mutex`/`Condition`/
`Semaphore`/`Barrier`/`JoinHandle` に既に使われる同じ単一割り当て
イディオムで `pthread_t` を直接埋め込む専用タグ
(`IDRIS2RC2_TAG_THREADID`、`datatypes.h`)を `ThreadID` に与える
ことで修正。Channel 自身の見直しはさらに、テスト中に見つかった
本物の use-after-free を修正した: `channelPut` の生成 FFI ラッパは
呼び出しが返った直後に値への自身の参照を drop するが、キューに
入ったノードはその呼び出しより長生きする -- `idris2rc2_fork`
自身の `dup` が既に記録する「FFI 呼び出しは引数を消費する」規約と
同じで、並行な `Integer` 値の `Channel` テストが `libgmp` の内部で
クラッシュするまでここでは見落とされていた。

## 展望

この文書自身の旧 "Not yet implemented" リスト(と `TODO.md` の
Concurrency セクション)が名前を挙げていたすべての項目は今や
実装済み。ここでの将来の作業のために覚えておく価値のある 2 つ。
どちらも今日何かをブロックするものではない:

- rc2 の `Mutex`/`Condition`/`Semaphore`/`Barrier`/`JoinHandle` は
  すべて、上流の `[external]` marshal が許可する形状をちょうど
  持つ pthread オブジェクトで裏打ちされるが、その形状について
  異なるバックエンドから見える・再利用できるものは何もない --
  呼び出し側は不透明な上流の型しか見ないので、実際上これは移植性
  の制約ではなく、将来のバックエンド比較パスが具体的な表現を検査
  するなら覚えておく価値があるだけである。
- `channelGetWithTimeout` の単一 wait 予算(上記 "設計: Channel")
  は正確なデッドライン追跡ではなく意図的に単純である。呼び出し側
  が実際に精密なデッドライン意味論を必要とするときだけ見直す;
  この段階自身のテスト中にそれを必要とするものは何も見つからな
  かった。
