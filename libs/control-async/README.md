# control-async

*[日本語](README.ja.md)*

Cooperative tasks for rc2: the `Task` monad with spawn/both/race and cancellation, a scheduler over `epoll` (and timers, and `io_uring` when liburing is there), `Ref`/`MVar`/`Chan` for tasks that share state on several threads, and non-blocking sockets for it (`Network.Async`). It was split off `rc2base`, which keeps the system-call layers it is built on (`System.Linux.*`, `System.Posix.*`, `Network.Address`, `Network.RC2`, `Data.Queue`, `System.Concurrency.RC2`). The HTTP servers and clients that run on tasks are in `web`. Like `rc2base` it is rc2-only.

A program uses it with `-p control-async -p rc2base -p contrib`. It has no C code of its own, and it does not need liburing unless `Control.Task.Uring` is used.

## Modules

| Module | What it is |
| --- | --- |
| `Control.Task` | the `Task` monad: spawn/both/race, cancellation, timers, `handoff`, `finally` -- see `doc/task.md` |
| `Control.Task.Scheduler` | the scheduler that runs tasks (`runTaskWith`, `Env`, `turn`) |
| `Control.Task.Source`, `Control.Task.Epoll` | pluggable event sources, and the `epoll` one |
| `Control.Task.Uring` | `io_uring` as an event source, on `System.Linux.Uring` of rc2base (needs liburing only if used) |
| `Control.Task.Pool`, `Control.Task.Waiters` | the worker threads that run actions in parallel mode, and the wait lists shared by the primitives below |
| `Control.Task.Ref`, `MVar`, `Chan` | state shared between tasks on several threads |
| `Network.Async` | `accept`, `connect`, `recv` and `send` that wait for the descriptor on the scheduler instead of blocking a thread |

## Tests

Same layout as `libs/rc2base/tests`: one directory per test under `tests/<TestName>/` with `<TestName>.idr` and `<TestName>.expected`, listed in the `TESTS` array of `tests/verify.sh`. The script type-checks and installs the package, then builds and runs every test with `-p control-async -p rc2base [-p <extra>...]`. `rc2base` has to be installed first (`libs/rc2base/tests/verify.sh` does it). `TestTaskUring` is skipped (with a `SKIP` line) when `gcc` cannot find `liburing.h`; `TestTaskNoUring` checks that a program which imports `Control.Task.Uring` but does not use it builds without liburing. `TestNetworkAsync` uses the `network` package as the client.
