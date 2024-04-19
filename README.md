# asyncssh2
Execute commands and upload/download files using multiple processes and asynchronous methods via SSH.

clone from: https://github.com/yglukhov/asyncssh

- Add support for Windows
- Add GC safe, can be used in multi-threaded manner
- Add support for executing commands and transferring files with timeouts.

`s.exec("cat /tmp/test1.nim",timeout=10)`

```
  let s = waitFor asyncssh2.newSshSession("ip", Port(22), "user", "password#")
  waitFor s.putFile("tests/test1.nim", "/tmp/test1.nim")
  echo waitFor s.exec("cat /tmp/test1.nim")
  waitFor s.getFile("/tmp/test1.nim", "test1.nim")

  s.shutdown()
```
