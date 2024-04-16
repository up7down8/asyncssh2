# This is just an example to get you started. You may wish to put all of your
# tests into a single file, or separate them into multiple `test1`, `test2`
# etc. files (better names are recommended, just make sure the name starts with
# the letter 't').
#
# To run these tests, simply execute `nimble test`.

import unittest
import asyncdispatch
import asyncssh2

test "can add":
  let s = waitFor asyncssh2.newSshSession("ip", Port(22), "user", "password#")
  waitFor s.putFile("tests/test1.nim", "/tmp/test1.nim")
  echo waitFor s.exec("cat /tmp/test1.nim")
  waitFor s.getFile("/tmp/test1.nim", "test1.nim")
  
  s.shutdown()
 
