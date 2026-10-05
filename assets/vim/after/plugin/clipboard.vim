if exists('g:loaded_vim_tools_clipboard')
  finish
endif
let g:loaded_vim_tools_clipboard = 1

if has('clipboard')
  nnoremap <silent> <C-c> "+yy
  xnoremap <silent> <C-c> "+y
  nnoremap <silent> <C-v> "+p
  xnoremap <silent> <C-v> "+P
  inoremap <silent> <C-v> <C-r>+
  cnoremap <silent> <C-v> <C-r>+
else
  nnoremap <silent> <C-c> yy
  xnoremap <silent> <C-c> y
  nnoremap <silent> <C-v> p
  xnoremap <silent> <C-v> P
  inoremap <silent> <C-v> <C-r>"
  cnoremap <silent> <C-v> <C-r>"
endif
