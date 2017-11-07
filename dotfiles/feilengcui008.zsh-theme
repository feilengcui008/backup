local ret_status="%(?:%{$fg_bold[green]%}\$:%{$fg_bold[red]%}\$)"
#PROMPT='%{$fg[green]%}%n@%m%{$reset_color%} %{$fg[blue]%}%~%{$reset_color%} $(git_prompt_info) ${ret_status}%{$reset_color%} %{$fg_bold[green]%}:-)%{$reset_color%} '
PROMPT='%{$fg[green]%}%n@%m%{$reset_color%} %{$fg[blue]%}%~%{$reset_color%} ${ret_status}%{$reset_color%} %{$fg_bold[green]%}:-)%{$reset_color%} '
