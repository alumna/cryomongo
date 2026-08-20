# Cursor kind for runCursorCommand and find. Matches the CRUD CursorType enum.
enum Mongo::CursorType
  NonTailable
  Tailable
  TailableAwait
end
