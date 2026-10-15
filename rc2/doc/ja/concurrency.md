# 並行実行(`rc2/support/rc2/`)

(原文: `doc/concurrency.md`。内容が乖離した場合は原文を正とする。)

rc2のランタイムが並行実行をどう扱うかについて、実装上の注意点をまとめる。実装は3段階で進めた。

1. 参照カウントを複数のスレッドから操作しても安全にした。
2. 実際のOSスレッドの生成(`refc_fork`)とMutex/Conditionを動くようにした。
3. 第2段階で残っていた`System.Concurrency`系のプリミティブ(`conditionWaitTimeout`、`getThreadId`、`setThreadData`/`getThreadData`、`Semaphore`、`Barrier`、`Channel`)をすべて実装し、rc2固有のjoin可能なforkを加えた。

3段階とも完了している。実装済みの内容は「ステータス」に詳しく書いた。

この文書でIdrisレベルのAPIを新たに増やすのは、rc2固有のjoin可能なfork(`forkJoin`/`join`/`JoinHandle`)だけである。パッチを当てるべき上流の宣言が存在しないためで、理由は「設計: join可能なfork」で述べる。`Channel`を含む残りはすべて、`%foreign_impl`で上流`System.Concurrency`の既存宣言に実装を与えるものである(`Channel`の経緯は「設計: Channel」を参照)。既存の型や関数はそのまま使え、スタブだったものが実際のスレッドとpthreadのプリミティブで動くようになる。

この文書は、将来の担当者(将来の自分を含む)が、設計を一から導き直したり、すでに判明している制約を再発見したりせずに、全体の事情を把握できるように書いている。後続の段階が完了するたびに更新するliving documentである。

(日本語訳: `doc/ja/concurrency.md`。更新は依頼があったときだけである。編集のたびに更新しているのは、この英語の原文のほうである。)

## 背景

rc2のランタイム(`rc2/support/rc2/`)は、上流RefC自身のサポートライブラリの流れをくむ。このライブラリは全体としてシングルスレッドでの実行を前提にしている。参照カウントは通常の非アトミックな整数であり、普通の`++`/`--`で更新する。rc2も、歴史の大半でこの前提をそのまま引き継いでいた(`TODO.md`にあった旧項目 "Concurrency: unchanged from RefC" は、現在この文書に置き換わっている)。

rc2の歴史の大半、そして後述のアトミック参照カウントの段階までは、rc2が実際のOSスレッドを生成することはなかった。`%foreign "C:refc_fork"`(`rc2/support/rc2/ioprims.c`。Idris2の`prim__fork`の実体)はスタブで、"Threads not implemented in the rc2 backend!" と表示してから、スレッドを生成せずに`exit(0)`を呼んでいた。

実スレッド生成の段階でこれが変わった(後述の「設計: 実スレッド生成」を参照)。`refc_fork`は今ではdetach済みの`pthread`を実際に生成するため、参照カウントの更新はスレッド間で本当に競合しうる。後述のアトミック表現と、「実スレッド生成によって顕在化した競合の解消」で述べる修正は、これを安全にするためのものである。

`refc_fork`が実際に動く前に参照カウントをアトミックにしたのは、意図的な下準備だった。コードがその正しさに依存する前に表現を正しくしておけたので、後続の実スレッド生成の段階は、範囲の明確な追加作業で済んだ。この文書がその段階に向けて用意した課題一覧(3か所の素のデクリメントと、小整数の遅延初期化フラグ。後述)は、そのまま次の段階で加えるべき差分になった。時間に追われながら、リスクの高い逆解析をもう一度やり直す必要はなかった。

## 設計: アトミック参照カウントと、このメモリオーダーを選んだ理由

2026-09-27以降、これらのアトミック操作を使うのは、プログラムがマルチスレッドになってからに限る。それまでは、参照カウントの更新はすべて素の操作であり、破棄の前のacquireはフェンスではなくロードで済ませる。詳しくは`hybrid-refcount.md`を参照すること。マルチスレッドになったあとに使うメモリオーダーは、以下に述べるものと同じである。

この段階で変更したファイルは`idris2rc2_datatypes.h`、`memory.c`、`runtime.h`である。`memory.h`と`runtime.c`は変更しなかった。当時それで安全だった理由と、実スレッド生成が入って何が変わったかは、後述の「実スレッド生成によって顕在化した競合の解消」を参照すること。

- **`idris2rc2_datatypes.h`**: `IDRIS2RC2_Header.refCount`を`uint16_t`から`_Atomic uint16_t`に変更した(`<stdatomic.h>`をincludeするようにした)。ファイル冒頭にあるヘッダのコメントは「非アトミックな参照カウント」と説明していたので、これも合わせて更新した。
- **`memory.c`、`idris2rc2_dup`**: インクリメントは`atomic_fetch_add_explicit(&v->header.refCount, 1, memory_order_relaxed)`になった。ここで`relaxed`で足りるのは、すでに生存が分かっているカウント(呼び出し側がすでに参照を持っている)を増やすだけなら、ほかのメモリを公開することも観測することも必要ないからである。それまでのすべての読み手と同期する必要があるのは、*ゼロに達するデクリメント*のほうであって、インクリメントではない。
- **`memory.c`、`idris2rc2_drop`**: デクリメントは`atomic_fetch_sub_explicit(&v->header.refCount, 1, memory_order_release)`になった。その戻り値(デクリメント*前*のカウント)が`1`かどうかを調べ、`1`のときだけ、`idris2rc2_teardown`を呼ぶ直前に`atomic_thread_fence(memory_order_acquire)`を実行する。これは、releaseデクリメントと、ゼロに達したときのacquireフェンスを組み合わせる標準的なパターンである。

  - すべてのデクリメントに付けた`release`により、各スレッドが指し先に行った書き込みと、自分の参照のdropが、*最後の*デクリメントを行うスレッドから見えるようになる。
  - カウントがゼロになるのを実際に観測したスレッドだけが払う`acquire`フェンスにより、そのスレッドは、値の破棄を始める前に、ほかのすべてのスレッドのreleaseを確実に見られる。
  - acquireフェンスを破棄経路に限らずdropのたびに無条件に払っても正しさは変わらない。しかし、最終dropでないことがほとんどである通常の場合に、無駄なコストがかかる。

  直上にある不死のチェック(`refCount == IDRIS2RC2_REFCOUNT_MAX`)は、素の非アトミックな比較のままにしてある。不死になった値の`refCount`は、以後誰も書き込まないため安全である(`idris2rc2_dup`自身の`!= IDRIS2RC2_REFCOUNT_MAX`ガードと、当時の`idris2rc2_getSmallInteger`における小整数キャッシュの初期化を参照)。このフィールドを同時に読むスレッドと競合する書き込みが、存在しない。
- **`runtime.h`、`idris2rc2_isUnique`**: `atomic_load_explicit(&(x)->header.refCount, memory_order_acquire) == 1`になった。ここで`acquire`が必要なのは、単に便利だからではない。`refCount == 1`を観測することは、インプレース更新を許可する根拠になる(コンストラクタ再利用などが依拠する「このスレッドが唯一の所有者である」という論拠)。したがってその観測は、カウントを最後に1まで下げたほかのスレッドの`release`デクリメントよりあとに起きなければならない。そうでなければ、最後に共有されていた状態の反映がまだ終わっていない値を、このスレッドが更新し始めかねない。

  この関数は、型付きの`static inline`関数ではなく、意図的にマクロのままにしてある。`IDRIS2RC2_Header header`を先頭フィールドに持つ*任意の*構造体型に対して汎用であり続けるためで、各呼び出し箇所が持つ具体的なポインタ型(たとえば`IDRIS2RC2_Constructor *`)にそのまま対応する。マクロにしてあった理由は、この変更の前から変わらない。

## 設計: 実スレッド生成(`refc_fork`)

変更したファイルは`ioprims.c`である(`util.h`と`<pthread.h>`を新たにincludeした)。

`refc_fork`は、forkされたクロージャを、detach済みの実際の`pthread`上で実行する。

- `pthread_create`を呼ぶ前に、クロージャを`idris2rc2_dup`する。複製したポインタは小さなトランポリン(`idris2rc2_threadTrampoline`)に渡す。トランポリンは、`idris2rc2_applyClosure`で消去済みの`%World`トークンにクロージャを適用し、結果をdropする。

  このdupは、省略可能な後始末ではない。この段階のテスト中に見つかったuse-after-freeを直すためのものである。生成された`prim__fork`のラッパーは、`refc_fork`が戻った直後に、クロージャへの自分の参照をdropする(「FFI呼び出しは引数を消費する」という通常の規約)。ところが生成されたスレッドは、その後もずっと同じポインタを使い続ける。dupがなければ、呼び出し側のdropによって、スレッドがまだ実行中のクロージャが解放されてしまいかねない。
- スレッドはjoinせず、生成の直後に`pthread_detach`する。これは、実際に到達できるものに合わせた設計である。生成したスレッドをjoinできるIdrisレベルのプリミティブは`threadWait`だけだが、上流の`System.Concurrency.idr`ではScheme専用で、Cバックエンドの実装がまったくない。`refc_fork`自身がどう振る舞うかにかかわらず、rc2(やRefC)からは到達できない。したがって、fire-and-forgetのdetach済みスレッドは手抜きではない。現状で呼び出し側が観測できる唯一の挙動である。
- 返す`ThreadID`は、専用の`IDRIS2RC2_TAG_THREADID`の値(`idris2rc2_datatypes.h`)で、`pthread_t`を直接埋め込む。ヒープに確保した`pthread_t`を包む汎用の`IDRIS2RC2_Pointer`ではない(そのteardownは`pthread_t`を決して解放しない。「ステータス」を参照)。

  上流のIdris2で`ThreadID`は`[external]`であり、rc2はこれをCFUserとして扱う(制約のない`IDRIS2RC2_Value*`をそのまま素通しする。`Compiler.RC2.Emit.Util`の`packCFType`/`extractValue`を参照)。そのため、形が正しい値であれば何でも使える。しかも`threadWait`がこの値を読むことは決してないので(上記)、タグを設けるのは、値を正しく解放するためだけである。

## 実スレッド生成によって顕在化した競合の解消

`refc_fork`が実際に動くようになった(上記)結果、複数のスレッドがようやく並行に走れるようになった。これにより、`runtime.c`の3か所と`memory.c`の1か所が、初めて到達可能な競合になった。4つとも現在は修正済みである。この節では、この段階の前になぜ安全だったのかという元の理由づけを残し、何を変えたかを記録する。

**`idris2rc2_trampoline`、`idris2rc2_tailcallApplyClosure`、`idris2rc2_dropReuseConstructor`(`runtime.c`)。** この段階の前は、3つとも`refCount`に素の`--`/`==`を行うだけで、ゼロに達したかどうかのチェックがまったくなかった。`refCount`が`_Atomic uint16_t`になったあとでも、これはそのままコンパイルでき、正しく動いていた。`_Atomic`な変数に対する素の`--`/`==`は、C11では暗黙のアトミックな複合代入/比較(既定は`memory_order_seq_cst`)になるので、型エラーも未定義動作もなかったからである。

ただし、**シングルスレッド実行という不変条件**に依存していた。3つはいずれも「一意でない」分岐でしか実行されず、その分岐では`annotate`自身の所有権解析により、カウントが入った時点で2以上だと分かっている。そのため素のデクリメントでゼロに達することはない。これが成り立つのは、同じ値を同時にdropしうるほかのスレッドがいないからにすぎない。修正は次のとおりである。

- `idris2rc2_trampoline`: `isUnique(c) ? free(c) : --c->header.refCount`という分岐は、無条件の`atomic_fetch_sub_explicit(..., memory_order_release)`1つになった。これが`1`を返したとき(その前に`atomic_thread_fence(memory_order_acquire)`を置く)に限り`c`を解放する。`idris2rc2_drop`がすでに使っていた、releaseデクリメントとゼロ時のacquireフェンスの組み合わせと同じパターンである。ここで解放するのはクロージャの殻だけで、`idris2rc2_drop`による完全な破棄ではない。`dispatchClosure`が引数の所有権をすでに消費しているので、引数を再度dropすると二重dropになる。
- `idris2rc2_tailcallApplyClosure`: 引数は新しいクロージャに奪われるのではなく`dup`されて渡る。したがって`c`自身の参照は通常どおり解放すればよく、素の`--c->header.refCount;`は、普通の`idris2rc2_drop((IDRIS2RC2_Value *)c)`の呼び出しに置き換えた。
- `idris2rc2_dropReuseConstructor`: `idris2rc2_trampoline`と同じく、releaseデクリメントとゼロ時のacquireフェンスに置き換えた。ただしここでの置き換えは、実際の競合の修正というより念のためのものである。この関数が呼ばれるのは、`idris2rc2_isUnique`ですでに一意性が静的に確認されている値に対してだけなので(`reuse-analysis.md`を参照)、どのみち、ほかのスレッドがこの`refCount`に同時に触ることはない。素のアクセスがたまたま安全である理由を別に論じるのをやめて、ほかのすべての`refCount`操作と同様にアクセスをアトミックにした、ということである。

この制約を説明するために、`runtime.h`の`idris2rc2_isUnique`の直上にあった1行の "Why not" コメントは、もう当てはまらなくなったため削除した。

**`idris2rc2_getSmallInteger`の遅延初期化フラグ(`memory.c`)。** この段階の前の`idris2rc2_smallIntegerInit`は、素の非アトミックな`static bool`であり、同期なしの「チェックしてからセットし、初期化ループを回す」という古典的なパターンを駆動していた。これが安全だったのは、2つのスレッドが同時に呼ぶことがなかったからにすぎない。実際に複数のスレッドが同時に最初の呼び出しをすると、初期化ループが2回以上実行されたり、一部しか初期化されていないキャッシュをあるスレッドが観測したりしうる。

修正として、フラグを`pthread_once_t`と`idris2rc2_initSmallInteger`の組に置き換え、`pthread_once`経由で駆動するようにした。これにより、初期化ループが厳密に1回だけ実行されること、そしてどのスレッドから呼んでも、完全に初期化されたキャッシュしか観測されないことが保証される。

## 設計: Mutex/Condition

上流Idris2の`System.Concurrency`モジュールは、`Mutex`、`Condition`、`makeMutex`、`mutexAcquire`、`mutexRelease`、`makeCondition`、`conditionWait`、`conditionSignal`、`conditionBroadcast`を`%foreign`プリミティブとして宣言している。しかし実装はSchemeバックエンド向けしかなく、RefCを含むすべてのCバックエンドは、これまで使えなかった。

実装した設計に決める前に、次の2つの案を検討した。

- **pthreadオブジェクトを`GCAnyPtr`で包む案**(rc2に既存の、任意のペイロードとファイナライザを持つポインタ型)。却下した。`GCAnyPtr`は、ファイナライザを通常の`PrimIO ()`のクロージャ適用の経路で実行するため、破棄のたびにクロージャ適用の全コストがかかる。ところがペイロード(`pthread_mutex_t`/`pthread_cond_t`)に必要なのは、あらかじめ決まったCの破棄関数を呼ぶことだけである。
- **既存の`Mutex`/`Condition`を実装し直すのではなく、Idris側に新しい`data`型と専用のFFIを導入する案**。却下した。この案では、すべての呼び出し側が`System.Concurrency`ではなくrc2固有のモジュールに依存することになり、上流のAPIに対して書かれたコードの移植性が、何の利益もなく損なわれる。`Mutex`/`Condition`の既存のシグネチャには、変える必要のあるところがなかった。

代わりに実装したのは次のものである。

- **`%foreign_impl`**(`libs/rc2base/src/System/Concurrency/RC2.idr`)。これはIdris2の既存のディレクティブで(`idris2-src/docs/source/ffi/ffi.rst`を参照)、別のモジュールにある*既存の*プリミティブ宣言に、そのモジュールに手を入れずに、具体的な`%foreign`実装を付けられる(`idris2-src`は読み取り専用の上流クローンであり、編集しない)。呼び出し側は、通常の`System.Concurrency`に加えて`System.Concurrency.RC2`をimportするだけでよい。`Mutex`、`Condition`、`makeMutex`など上流APIの残りは、そこから先はまったく変更なしで動く。新しい型も関数も、どこにも導入しない。
- **`IDRIS2RC2_Value`のネイティブなタグを2つ追加**: `IDRIS2RC2_TAG_MUTEX`/`IDRIS2RC2_TAG_CONDITION`(`idris2rc2_datatypes.h`)。それぞれ1回の確保で済む構造体で、`pthread_mutex_t`/`pthread_cond_t`をヘッダ付きの値に直接埋め込む(ポインタの間接参照を増やさない)。

  これが可能なのは、上流が`Mutex`/`Condition`を`[external]`と宣言しているからである。rc2は`[external]`をCFUserとして扱う(制約のない`IDRIS2RC2_Value*`をそのまま素通しする。`Compiler.RC2.Emit.Util`の`packCFType`/`extractValue`を参照)ので、正しいタグを持つ値であれば何でも有効な値になる。専用のタグを付けてpthreadオブジェクトをインラインに置く形は、この条件を満たす最も単純な形である。さらに、参照カウントがゼロになったときに`idris2rc2_teardown`(`memory.c`)が`pthread_mutex_destroy`/`pthread_cond_destroy`を自動的に呼べる。`IDRIS2RC2_TAG_BUFFER`が自分のバッファを解放するのと同じやり方であり、Idris側に明示的な`free`プリミティブは要らない。
- 実際の`pthread_mutex_*`/`pthread_cond_*`の呼び出しは`libs/rc2base/support/c/concurrency_util.c`にあり、`%foreign_impl`の接続先になっている(`idris2rc2_mutex_make`、`idris2rc2_mutex_acquire`、`idris2rc2_mutex_release`、`idris2rc2_condition_make`、`idris2rc2_condition_wait`、`idris2rc2_condition_signal`、`idris2rc2_condition_broadcast`)。

## 設計: SemaphoreとBarrier

上のMutex/Conditionと同じ方式であり、理由も同じである。上流の`System.Concurrency`は、`Semaphore`/`makeSemaphore`/`semaphorePost`/`semaphoreWait`と、`Barrier`/`makeBarrier`/`barrierWait`を`%foreign`プリミティブとして宣言しているが、実装はScheme向けしかない。`%foreign_impl`(`libs/rc2base/src/System/Concurrency/RC2.idr`)を使えば、上流に手を入れずに、これらの既存の宣言にCの実装を付けられる。

ネイティブなタグを2つ追加した。`IDRIS2RC2_TAG_SEMAPHORE`/`IDRIS2RC2_TAG_BARRIER`(`idris2rc2_datatypes.h`)で、それぞれ`sem_t`/`pthread_barrier_t`をヘッダ付きの値に直接埋め込む。`IDRIS2RC2_TAG_MUTEX`/`_CONDITION`がすでに使っている、1回の確保で済む形と同じである。参照カウントがゼロになると`idris2rc2_teardown`(`memory.c`)が`sem_destroy`/`pthread_barrier_destroy`を呼ぶので、Idris側に明示的な解放プリミティブは要らない。pthreadとセマフォを実際に呼ぶ部分(`idris2rc2_semaphore_make`/`_post`/`_wait`、`idris2rc2_barrier_make`/`_wait`)は、`libs/rc2base/support/c/concurrency_util.c`にある。

`conditionWaitTimeout`と`getThreadId`も`%foreign_impl`によるパッチだが、新しいタグは要らない。`idris2rc2_condition_wait_timeout`は`pthread_cond_timedwait`を包んでいて、呼び出し側が渡したマイクロ秒数から、`CLOCK_REALTIME`を基準にした絶対時刻のデッドラインを計算して使う。`idris2rc2_get_thread_id`はLinuxの`gettid()`を包んでいる(`_GNU_SOURCE`が必要である)。

`setThreadData`/`getThreadData`は、`_Thread_local IDRIS2RC2_Value *`を1つ用意し、OSスレッドごとに1スロットを持たせて実現している。`idris2rc2_set_thread_data`は、スロットを上書きする前に、スロットが持つ以前の値をdropする。これは通常の参照カウントの規律であり、新しい仕組みではない。`idris2rc2_get_thread_data`は、値を返す前に`dup`する。呼び出し側は自分用の新しい参照を受け取り、スレッドローカルのスロットは自分の参照を保ったままにするためである。

## 設計: join可能なfork(`forkJoin`/`join`、`JoinHandle`)

上流の`System.Concurrency.idr`には、パッチを当てられるjoin可能なforkに相当するものがない。`ThreadID`/`threadWait`は、どのCバックエンドでも何もjoinできない(`threadWait`はScheme専用である)。これは、上の「設計: 実スレッド生成」が、`refc_fork`を無条件にdetachする根拠として使っている到達不能性と同じ事情である。

そこで`forkJoin`/`join`/`JoinHandle`は、`%foreign_impl`によるパッチではなく、新しい`%foreign`宣言として用意した(`libs/rc2base/src/System/Concurrency/RC2.idr`)。上流にはまったく存在しない、本当に新しいIdrisレベルのAPIである。

新しいタグ`IDRIS2RC2_TAG_JOINHANDLE`(`idris2rc2_datatypes.h`)は、生の`pthread_t`と`joined : bool`フラグを保持する。`idris2rc2_fork_join`(`concurrency_util.c`)は、`idris2rc2_fork`自身のトランポリン(`ioprims.c`)と同じ作りで、同じuse-after-freeを避けるため`pthread_create`の前にクロージャを`dup`することも共通している。違うのは、joinが必要になりうるので、スレッドをdetach*しない*で生成する点である。`idris2rc2_join`は`pthread_join`を呼んで`joined = true`にする。

`joined`フラグがあるので、`idris2rc2_teardown`の`IDRIS2RC2_TAG_JOINHANDLE`の処理は、ハンドルがどちらの形でdropされても正しく動く。

- 一度もjoinされないままdropされた場合、teardownは`pthread_detach`を呼び、スレッドがゾンビにならないようにする。
- すでにjoinされていた場合、teardownは何もしない。`pthread_join`がスレッドを回収済みで、その`pthread_t`はもう有効な識別子ではなく、再び触る(2度目のdetachやjoinをする)のは未定義動作だからである。

`join`は、ハンドル1つにつき最大1回しか呼べないとドキュメントに書いてある。型で一意性を強制できないのは、上流の`Mutex`/`Condition`のAPIと同じである。ドキュメント以外には、呼び出し側が2回呼ぶのを妨げるものはない。

## 設計: Channel

Channelは、この段階のプリミティブの中で、当初は`%foreign_impl`ではまったく実装できない唯一のものだった。`channelGetNonBlocking`/`channelGetWithTimeout`は`Maybe a`を返す。ところが、ランタイムの汎用Cコードから、任意のコンパイル結果における`Just`を組み立てるのは、一般には安全でないように見えた(調査の全容はTODO.mdの "Dropped: unwrapping `Just x` to a bare `x`" の項を参照)。プログラムに依存せず固定された規約があるのは、`Nothing`のNULL表現だけである。

そのためChannelの最初の版は、`Maybe`の構築をまったく避けた。すでに検証済みのMutex/Condition/IORefのプリミティブの上に、普通のIdris(`MkChannel (IORef (List a)) Mutex Condition`)で実装し、上流の`Channel`を`%hide`で隠して、新しい`Channel`型を独自に定義していた。

その後これを見直して、`%foreign_impl`による実装に置き換えた。`System.Concurrency`自身の`prim__makeChannel`/`prim__channelGet`/`prim__channelGetNonBlocking`/`prim__channelGetWithTimeout`/`prim__channelPut`にパッチを当てる形で、この文書のほかのプリミティブと同じ方式である。

これは、TODO.mdが不健全だとして見送った、一般的な「`Just x`を`x`に展開する」案とは**別のもの**である。あの案は、任意のペイロード型に対してConstructorの確保を*省こう*とするもので、ペイロード自身がNULLで表現できる場合(`Just []`、`Just ()`、`Just Nothing`など)に`Nothing`と衝突する。`idris2rc2_channel_get_non_blocking`/`_get_with_timeout`(`libs/rc2base/support/c/concurrency_util.c`)が行うのは、もっと範囲が狭く、かつ健全なことである。`Just`については常に本物の`IDRIS2RC2_Constructor`を*構築*し(`idris2rc2_newConstructor(1, 1)`)、`Nothing`については`NULL`を返す。確保を省くことはしない。

これが成り立つのは、`Prelude.Maybe`のタグ割り当てが、プログラムに依存しない固定の事実だからである。実験で確認済みで、普通の`Just x`は`idris2rc2_newConstructor(1, 1)`にコンパイルされ、`ConstFold`が段階的に静的化する`Just []`も同じタグとアリティを使う。これは**文書化された制約**であって、一般的な手法ではない。`Prelude.Maybe`が、すべてのrc2プログラムで共有される、バージョン管理された固定のライブラリ型であること(プログラムごとにユーザーが定義するADTではないこと)に依存しており、将来のIdris2が`Nothing`/`Just`の宣言順を入れ替えれば成り立たなくなる。

`Channel a`は、新しいネイティブタグ`IDRIS2RC2_TAG_CHANNEL`(`idris2rc2_datatypes.h`)で実現している。`pthread_mutex_t`/`pthread_cond_t`を埋め込み、これらで保護する、所有された`IDRIS2RC2_Value*`のノードからなる単方向リンクリストのFIFOキューである。

- `channelPut`はノードを追加してシグナルを送る。その際、先に値を`idris2rc2_dup`する。生成されたFFIラッパーは、呼び出しから戻った直後にすべての引数への自分の参照をdropするが(`idris2rc2_fork`/`idris2rc2_fork_join`の`dup`がすでに記している規約と同じ)、ここではノードが呼び出しより長く生きるからである。
- `channelGet`は、キューが空の間は条件変数で待ち、そのあと取り出す。
- ノンブロッキング版とタイムアウト版は、それぞれ「取り出すか`NULL`」と「取り出すか、1回だけ待って取り出すか`NULL`」である。タイムアウト版は、「1回の待ちで予算全体をまかない、正確なデッドラインは追跡しない」という、前の版の単純さを引き継いでいる。
- `idris2rc2_teardown`のCHANNELの処理は、mutexとcondを破棄し、まだキューに残っているノードをたどって、保持している値をdropしてからノードを解放する。保留中で未受信のメッセージが残ったままdropされたchannelが、それらをリークしてはならないからである。

Channelが上流自身の宣言にパッチを当てる形になったので、前の版の`%hide`による回避策と、再利用できない独自の`Channel`型は、どちらもなくなった。呼び出し側は`import System.Concurrency`と`import System.Concurrency.RC2`を書くだけで、`System.Concurrency`自身の`Channel`/`makeChannel`/...を変更なしで使える。この文書のほかのプリミティブと同じである。

## 発見: `%foreign`の型ウィットネスは消去されない

`setThreadData`/`getThreadData`/`forkJoin`/`join`を実装している途中で分かった。`%foreign`プリミティブの多相な型パラメータ(暗黙の`{a : Type}`、または`a`が戻り値の型に現れるときにrc2自身のFFI規約が補うウィットネス)は、rc2のコード生成では**消去されない**。これは、コンパイラの消去ロジックを直接調べて確かめたのではなく、実際にビルドして生成されたCを読んで確認した。

このため、影響を受ける4つのC関数(`idris2rc2_set_thread_data`、`idris2rc2_get_thread_data`、`idris2rc2_fork_join`、`idris2rc2_join`。`concurrency_util.c`/`.h`)は、いずれも先頭に`IDRIS2RC2_Value *typeWitness`引数を取り、受け取ったあと即座に無視する。今後、シグネチャに多相の`a`がそのまま現れるプリミティブを作るときも、原理上は消去されるはずだと仮定せず、生成されたCをあらためて確認するほうがよい。

## ステータス

**参照カウントのアトミック化: 完了、検証済み。** `idris2rc2_datatypes.h`、`memory.c`、`runtime.h`は上述のとおり。検証は`rc2/tests/verify.sh`(refc-suite 19/19 PASS、スモークテスト32/32 PASS、`valgrind`のエラーはゼロ)と`rc2/tests/bench.sh`(上記の`relaxed`/`release`/`acquire`の選択による性能の低下は計測されなかった)で行った。`-Wall`ビルドもクリーンである。

**実スレッド生成(`refc_fork`)とMutex/Condition: 完了、検証済み。** `refc_fork`は、実際にdetach済みの`pthread`を生成するようになった(上記の「設計: 実スレッド生成」を参照)。これによって、アトミック参照カウントの段階で指摘した4つの競合が、初めて到達可能になった。4つとも修正済みである(上記の「実スレッド生成によって顕在化した競合の解消」を参照)。`Mutex`/`Condition`は、`System.Concurrency.RC2`の`%foreign_impl`によりrc2で使える(上記の「設計: Mutex/Condition」を参照)。

検証は次のとおり行った。

- `rc2/tests/verify.sh`(refc-suite 19/19 PASS、スモークテスト32/32 PASS、`valgrind`のエラーはゼロ)。
- `libs/rc2base/tests/verify.sh`(`TestText`/`TestTextTree`/`TestConcurrency`がすべてPASS)。新しい`TestConcurrency.idr`は、`fork`と`Mutex`と`Condition`を組み合わせて使い、複数のスレッドが共有カウンタをインクリメントして、条件を待つ。
- `valgrind --fair-sched=yes`と`helgrind`は、データ競合を報告しなかった。
- `rc2/tests/bench.sh`でも、性能の低下は計測されなかった。

**`System.Concurrency`系の残りのプリミティブ、join可能なfork、Channel: 完了、検証済み。** `conditionWaitTimeout`、`getThreadId`、`setThreadData`/`getThreadData`、`Semaphore`、`Barrier`、そして(後の見直しにより。上記の「設計: Channel」を参照)`Channel`自身が、`Mutex`/`Condition`と同じようにrc2で使える。どれも、上流にある既存のprim__宣言に`%foreign_impl`を当てる形である。rc2固有のjoin可能なfork(`forkJoin`/`join`/`JoinHandle`)は、上流自身がどのCバックエンドでも埋められない唯一の欠落を埋める(上記の「設計: join可能なfork」を参照)。

検証は`rc2/tests/verify.sh`(56件PASS、既知の既存の問題2件、失敗0件)と`libs/rc2base/tests/verify.sh`(`TestConcurrency.idr`を拡張してすべての新しいプリミティブを動かし、すべてPASS)で行った。さらに`valgrind --fair-sched=yes`と`helgrind`も、その時点では新しいエラーを報告しなかった。

この段落の以前の版で触れていた2つの積み残しは、どちらも解決している。

- 1つめは、繰り返しの`IORef`追記における`List.(++)`のリークである。`Compiler.RC2.RC`自身の`RExtPrim`の所有権注釈の欠落と原因が同じだと分かり、修正した(`doc/c-struct-support.md`の追記を参照)。
- 2つめは、`idris2rc2_fork`自身の`ThreadID`のmallocである。これはヒープ確保した`pthread_t*`を汎用の`IDRIS2RC2_Pointer`に包んでいたが、そのteardownは、外部が所有するペイロードを意図的に解放しない。rc2自身が確保したポインタには、これは誤りだった。`ThreadID`に専用のタグ(`IDRIS2RC2_TAG_THREADID`、`idris2rc2_datatypes.h`)を与え、`pthread_t`を直接埋め込むことで修正した。`Mutex`/`Condition`/`Semaphore`/`Barrier`/`JoinHandle`がすでに使っている、1回の確保で済む形と同じである。

Channelの見直しでは、さらに本物のuse-after-freeも修正した。テスト中に見つかったもので、`channelPut`が生成するFFIラッパーは、呼び出しから戻った直後に値への自分の参照をdropするが、キューに入ったノードは呼び出しより長く生きる。「FFI呼び出しは引数を消費する」という規約は`idris2rc2_fork`自身の`dup`がすでに記しているものだが、ここでは見落としていた。`Integer`を値とする`Channel`を並行に使うテストが`libgmp`の内部でクラッシュして発覚した。

**IORefのアトミックなcompare-and-swap: 完了、検証済み。** これは、上流のバックエンド非依存な`Data.IORef`が提供できるものではない(`Mut a`が`[external]`であり、Idris2のソースレベルでは構造が見えず、どのバックエンドもCASを組み立てられない)。rc2固有の追加であり、`Data.IORef.RC2.casIORef`(`libs/rc2base`)である。`expected`との比較は`Eq`ではなく参照の同一性で行う。

実装は、`readIORef`/`writeIORef`がすでに`IDRIS2RC2_IORef`自身の`v`スロットに対して取っているスピンロックをそのまま使う(`idris2rc2_ioref_cas`、`rc2/support/rc2/idris2rc2_ioprims.c`)。`v`だけを対象にしたロックフリーのハードウェアCASにしなかった理由は、この文書のほかの「設計」の節が繰り返し述べているものと同じである。素のアトミックなポインタ交換では、並行する読み手の「ロードしてからdupする」手順を保護できない。そのため、同じスロットにロックフリーの書き手を混ぜると、スピンロックが閉じているはずのuse-after-freeを、そのまま再び開くことになる。

戻り値は`Maybe a`である。

- 成功は`Nothing`で、`Compiler.RC2.Emit`自身の`RCon`/`RConCase`はこれを素の`NULL`で表現する。成功が期待される通常の経路では、確保がまったく起きない。
- 失敗は`Just <実際にそこにあった値>`である(`idris2rc2_wrapJust`、`idris2rc2_memory.c`)。これは、`idris2rc2_channel_get_non_blocking`/`idris2rc2_channel_get_with_timeout`がすでに持っていた、内容が同一の`static`ヘルパーを昇格させたものである。「Justはタグ1、アリティ1」という同じ規約を使うのがこれで2か所目になったためである。

確保が起きるのは、リトライループで失敗した試行のときだけである。しかも呼び出し側は、次の試行に使う値を、別の`readIORef`を呼ぶことなくアトミックに得られる。別に`readIORef`を呼ぶと、その間に並行する書き手と競合しうる。検証は`libs/rc2base/tests/verify.sh`(`TestIORefRC2.idr`で、成功、ウィットネス付きの失敗、リトライループ、Boxed(`String`)のペイロードをすべて確認し、すべてPASS)と、`valgrind --leak-check=full`でエラーなしであることで行った。

## 見通し

この文書の以前の段階で未実装のまま残していた項目(および`TODO.md`で管理していたもの)は、すべて実装済みになった。今後ここで作業するときは次の2点を覚えておくとよい。どちらも、現時点では何の妨げにもならない。

- rc2の`Mutex`/`Condition`/`Semaphore`/`Barrier`/`JoinHandle`は、いずれもpthreadのオブジェクトで実現していて、その形は上流の`[external]`の扱いが許すものと厳密に一致する。しかしこの形は、ほかのバックエンドからは見えず、再利用もできない。呼び出し側に見えるのは、不透明な上流の型だけである。したがって実際には移植性の制約にならないが、将来バックエンド同士を比較して具体的な表現を調べることがあれば、覚えておく価値がある。
- `channelGetWithTimeout`の「1回の待ちで予算全体をまかなう」やり方(上記の「設計: Channel」を参照)は、デッドラインを正確に追跡するものではなく、意図的に単純にしてある。正確なデッドラインの意味が実際に必要な呼び出し側が現れたときだけ、見直せばよい。この段階のテストでは、必要になった場面はなかった。
