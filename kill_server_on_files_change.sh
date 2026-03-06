while inotifywait -q -e modify,create,delete -r ./src/; do
  pkill chess_server
done

