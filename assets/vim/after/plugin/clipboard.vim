if exists('g:loaded_vim_tools_clipboard')
  finish
endif
let g:loaded_vim_tools_clipboard = 1

if has('clipboard')
  nnoremap <silent> <C-c> "+yy
  xnoremap <silent> <C-c> "+y
  nnoremap <silent> <leader>p "+p
  xnoremap <silent> <leader>p "+P
  inoremap <silent> <leader>p <C-r>+
  cnoremap <silent> <leader>p <C-r>+
else
  nnoremap <silent> <C-c> yy
  xnoremap <silent> <C-c> y
  nnoremap <silent> <leader>p p
  xnoremap <silent> <leader>p P
  inoremap <silent> <leader>p <C-r>"
  cnoremap <silent> <leader>p <C-r>"
endif
