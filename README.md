isync
=====

use inoitfywait and rsync to keep sync directory of two hosts/directory

impletement
===========
when event occurs, call rsync to rsync the change.

- two proccess:  
  **A** proccess inotifywait on the resource which be monited, and write event to event file : **EFILE**

  **B** proccess inotifywait on the **EFILE** , when event come on , it read the **EFILE** and produce synchronous.

- Event class:  
  **DELETE EVENT** :  delete file or directory, use rsync --delete to delete the pair side.

  *not* **DELETE EVENT** :  the others , use rsync to synchorize the change.


problem
========
each event trigger an rsync synchronous. Delete, create, write file will trigger sevral event, so trigger too many rsync
 proccess at a time. this maybe not suite to sence that file or directory change frequently.
