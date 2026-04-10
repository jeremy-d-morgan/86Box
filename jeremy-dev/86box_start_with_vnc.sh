#!/bin/bash
QT_QPA_PLATFORM=offscreen gdb -batch -ex run -ex bt \
  --args ~/86Box/86Box-dev-latest --headless -P ~/86Box/vms/IBM\ PC\ XT\ 5160/ \
  2>&1 | tee /tmp/86box-crash.log