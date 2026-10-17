GHC ?= ghc
BIN = bin/parser

all: $(BIN)

$(BIN): Parser.hs
	mkdir -p bin
	$(GHC) -O2 Parser.hs -o $(BIN)

clean:
	rm -f Parser.o Parser.hi $(BIN)

.PHONY: all clean
