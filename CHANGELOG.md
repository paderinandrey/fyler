## 1.1.0
* add priority support (customizable through config)
* add Honeybadger lager backend
* add 'get' and 'abort' task HTTP calls (as REST read and delete respectively)
* fix uploader bug 

## 1.0.0
* vagrant-ansible [configuration](https://github.com/palkan/fyler-vm)
* no more HTML/CSS, only JSON
* only works with S3
* add pool categories (and handlers categories)
* add pool max concurrent workers number
* add S3 ACL support
* auto-cleanup temp files
* add tests for checking conversions utils
* add video and audio conversion handlers
* add simple query support for completed tasks list (GET query: type, status, order (asc,desc), order_by, offset, limit)