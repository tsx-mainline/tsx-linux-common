# board.sh: point a test at the made-up board of tests/boards.
#   . "$(dirname "$0")/lib/board.sh"
# It exports two names:
#   TSX_BOARD_CONF   the board file (tests/boards/fake/board.sh)
#   TSX_BOARD_BIN    tsx-board of this repo, for the Python code
# A test that needs the other files of the board uses TSX_BOARD_DIR, for
# example $TSX_BOARD_DIR/panel-board.conf. TSX_TEST_BOARD, set before the
# call, picks another folder of tests/boards.
TSX_ROOT=${TSX_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
TSX_BOARD_DIR=$TSX_ROOT/tests/boards/${TSX_TEST_BOARD:-fake}
export TSX_BOARD_CONF=$TSX_BOARD_DIR/board.sh
export TSX_BOARD_BIN=$TSX_ROOT/base/usr/local/bin/tsx-board
