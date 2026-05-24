CC = clang
CFLAGS = -fobjc-arc -framework Foundation -framework IOKit -framework CoreFoundation
TARGET = wd_smart

all: $(TARGET)

$(TARGET): wd_smart.m
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)

install: $(TARGET)
	cp $(TARGET) /usr/local/bin/

.PHONY: all clean install
