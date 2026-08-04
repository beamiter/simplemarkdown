" Print the text-property classes the Vim side knows about, one per line, in
" declaration order.  `make check-classes` diffs this against
" `simplemarkdown-daemon --classes`.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/classes.vim
"
" writefile() rather than :echo — under -es the message area is not stdout,
" and a silent-ex Vim that prints nothing looks exactly like an empty list.

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)

call writefile(simplemarkdown#Classes(), '/dev/stdout')
qall!
