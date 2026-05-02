#!/bin/bash
# Run this script to unpack the Hybrid Inventory Manager project
# Usage: bash hybrid_inventory_manager.tar.gz.sh
echo "Unpacking Hybrid Inventory Manager..."
mkdir -p hybrid_inventory_manager/include
mkdir -p hybrid_inventory_manager/src
cd hybrid_inventory_manager
cat > include/inventory.h << 'HEADER_EOF'
/* ============================================================
 * inventory.h  –  C backend API for Hybrid Inventory Manager
 * All declarations use plain C to allow extern "C" linkage.
 * ============================================================ */
#ifndef INVENTORY_H
#define INVENTORY_H

#ifdef __cplusplus
extern "C" {
#endif

/* ── Data structure ─────────────────────────────────────────── */
typedef struct {
    int   id;
    char  name[40];
    int   quantity;
    float price;
    int   is_deleted;   /* 1 = soft-deleted, 0 = active */
} Item;

/* ── File used for persistence ──────────────────────────────── */
#define DB_FILE "inventory.dat"

/* ── Backend API ────────────────────────────────────────────── */

/**
 * add_item  – Append a new item to the binary file.
 *   Returns 1 on success, 0 if the ID already exists or file error.
 */
int add_item(const Item *item);

/**
 * get_item  – Load a single active item by ID into *out.
 *   Returns 1 on success, 0 if not found / deleted / file error.
 */
int get_item(int id, Item *out);

/**
 * update_item  – Overwrite an existing active record in-place.
 *   Returns 1 on success, 0 if not found / deleted / file error.
 */
int update_item(int id, const Item *updated);

/**
 * delete_item  – Soft-delete: sets is_deleted=1 in-place.
 *   Returns 1 on success, 0 if not found / already deleted / error.
 */
int delete_item(int id);

/**
 * list_items  – Fill *buffer with up to max_items active records.
 *   Returns the number of active items copied (0 if none / error).
 */
int list_items(Item *buffer, int max_items);

#ifdef __cplusplus
}   /* extern "C" */
#endif

#endif /* INVENTORY_H */
HEADER_EOF

cat > src/inventory.c << 'C_EOF'
/* ============================================================
 * inventory.c  –  C backend implementation
 * Uses fopen/fread/fwrite/fseek for binary file persistence.
 * ============================================================ */
#include <stdio.h>
#include <string.h>
#include "../include/inventory.h"

/* ── Internal helper: open the database file ────────────────── */
static FILE *open_db(const char *mode)
{
    return fopen(DB_FILE, mode);
}

/* ── add_item ────────────────────────────────────────────────── */
int add_item(const Item *item)
{
    if (!item) return 0;

    /* First pass: check for duplicate ID ---------------------- */
    FILE *fp = open_db("rb");
    if (fp) {
        Item tmp;
        while (fread(&tmp, sizeof(Item), 1, fp) == 1) {
            if (!tmp.is_deleted && tmp.id == item->id) {
                fclose(fp);
                return 0;   /* duplicate */
            }
        }
        fclose(fp);
    }

    /* Append the new record ------------------------------------ */
    fp = open_db("ab");
    if (!fp) return 0;
    size_t written = fwrite(item, sizeof(Item), 1, fp);
    fclose(fp);
    return (written == 1) ? 1 : 0;
}

/* ── get_item ────────────────────────────────────────────────── */
int get_item(int id, Item *out)
{
    if (!out) return 0;

    FILE *fp = open_db("rb");
    if (!fp) return 0;

    Item tmp;
    while (fread(&tmp, sizeof(Item), 1, fp) == 1) {
        if (!tmp.is_deleted && tmp.id == id) {
            *out = tmp;
            fclose(fp);
            return 1;
        }
    }
    fclose(fp);
    return 0;
}

/* ── update_item ─────────────────────────────────────────────── */
int update_item(int id, const Item *updated)
{
    if (!updated) return 0;

    FILE *fp = open_db("r+b");
    if (!fp) return 0;

    Item tmp;
    long offset = 0;
    while (fread(&tmp, sizeof(Item), 1, fp) == 1) {
        if (!tmp.is_deleted && tmp.id == id) {
            /* Seek back to the start of this record and overwrite */
            if (fseek(fp, offset, SEEK_SET) != 0) { fclose(fp); return 0; }
            size_t w = fwrite(updated, sizeof(Item), 1, fp);
            fclose(fp);
            return (w == 1) ? 1 : 0;
        }
        offset += (long)sizeof(Item);
    }
    fclose(fp);
    return 0;
}

/* ── delete_item ─────────────────────────────────────────────── */
int delete_item(int id)
{
    FILE *fp = open_db("r+b");
    if (!fp) return 0;

    Item tmp;
    long offset = 0;
    while (fread(&tmp, sizeof(Item), 1, fp) == 1) {
        if (!tmp.is_deleted && tmp.id == id) {
            tmp.is_deleted = 1;
            if (fseek(fp, offset, SEEK_SET) != 0) { fclose(fp); return 0; }
            size_t w = fwrite(&tmp, sizeof(Item), 1, fp);
            fclose(fp);
            return (w == 1) ? 1 : 0;
        }
        offset += (long)sizeof(Item);
    }
    fclose(fp);
    return 0;
}

/* ── list_items ──────────────────────────────────────────────── */
int list_items(Item *buffer, int max_items)
{
    if (!buffer || max_items <= 0) return 0;

    FILE *fp = open_db("rb");
    if (!fp) return 0;

    int count = 0;
    Item tmp;
    while (count < max_items && fread(&tmp, sizeof(Item), 1, fp) == 1) {
        if (!tmp.is_deleted) {
            buffer[count++] = tmp;
        }
    }
    fclose(fp);
    return count;
}
C_EOF

cat > src/InventoryManager.cpp << 'CPP_EOF'
/* ============================================================
 * InventoryManager.cpp  –  C++ frontend layer
 * Wraps the C backend with input validation, STL, and a menu.
 * ============================================================ */
#include <iostream>
#include <iomanip>
#include <string>
#include <vector>
#include <algorithm>
#include <limits>
#include <cctype>
#include <cstring>
#include "../include/inventory.h"

/* ── Maximum items we'll ever fetch for listing ─────────────── */
static const int MAX_BUFFER = 4096;

/* ============================================================
 * InventoryManager class
 * ============================================================ */
class InventoryManager {
public:
    /* Entry-point: run the interactive menu loop */
    void run();

private:
    /* ── Menu actions ─────────────────────────────────────── */
    void menuAddItem();
    void menuViewItem();
    void menuUpdateItem();
    void menuDeleteItem();
    void menuListItems();

    /* ── Display helpers ──────────────────────────────────── */
    static void printHeader();
    static void printRow(const Item &item);
    static void printDivider();
    static void printMenu();

    /* ── Input helpers ────────────────────────────────────── */
    static int    readInt(const std::string &prompt, int minVal, int maxVal);
    static float  readFloat(const std::string &prompt, float minVal);
    static std::string readNonEmptyString(const std::string &prompt, int maxLen);
    static void   clearInput();
    static void   pause();
};

/* ── run ─────────────────────────────────────────────────────── */
void InventoryManager::run()
{
    int choice = 0;
    do {
        printMenu();
        choice = readInt("Enter choice", 1, 6);
        std::cout << "\n";
        switch (choice) {
            case 1: menuAddItem();    break;
            case 2: menuViewItem();   break;
            case 3: menuUpdateItem(); break;
            case 4: menuDeleteItem(); break;
            case 5: menuListItems();  break;
            case 6: std::cout << "  Goodbye!\n\n"; break;
            default: break;
        }
    } while (choice != 6);
}

/* ── Menu: Add Item ──────────────────────────────────────────── */
void InventoryManager::menuAddItem()
{
    std::cout << "  ── Add Item ──────────────────────────────\n";
    Item item;
    std::memset(&item, 0, sizeof(item));

    item.id = readInt("  ID (positive integer)", 1, std::numeric_limits<int>::max());

    /* Check duplicate before filling all fields */
    Item probe;
    if (get_item(item.id, &probe)) {
        std::cout << "  [ERROR] An item with ID " << item.id << " already exists.\n";
        pause(); return;
    }

    std::string name = readNonEmptyString("  Name", 39);
    std::strncpy(item.name, name.c_str(), 39);
    item.name[39] = '\0';

    item.quantity = readInt("  Quantity (>= 0)", 0, std::numeric_limits<int>::max());
    item.price    = readFloat("  Price (>= 0.0)", 0.0f);
    item.is_deleted = 0;

    if (add_item(&item)) {
        std::cout << "  [OK] Item added successfully.\n";
    } else {
        std::cout << "  [ERROR] Could not add item (duplicate ID or file error).\n";
    }
    pause();
}

/* ── Menu: View Item ─────────────────────────────────────────── */
void InventoryManager::menuViewItem()
{
    std::cout << "  ── View Item ─────────────────────────────\n";
    int id = readInt("  Enter item ID", 1, std::numeric_limits<int>::max());

    Item item;
    if (get_item(id, &item)) {
        printHeader();
        printRow(item);
        printDivider();
    } else {
        std::cout << "  [ERROR] Item not found (ID=" << id << ").\n";
    }
    pause();
}

/* ── Menu: Update Item ───────────────────────────────────────── */
void InventoryManager::menuUpdateItem()
{
    std::cout << "  ── Update Item ───────────────────────────\n";
    int id = readInt("  Enter item ID to update", 1, std::numeric_limits<int>::max());

    Item existing;
    if (!get_item(id, &existing)) {
        std::cout << "  [ERROR] Item not found (ID=" << id << ").\n";
        pause(); return;
    }

    std::cout << "  Current values:\n";
    printHeader(); printRow(existing); printDivider();
    std::cout << "  Enter new values (press Enter to keep current):\n";

    /* Name */
    std::cout << "  Name [" << existing.name << "]: ";
    std::string input;
    std::getline(std::cin, input);
    if (!input.empty()) {
        std::strncpy(existing.name, input.substr(0, 39).c_str(), 39);
        existing.name[39] = '\0';
    }

    /* Quantity */
    std::cout << "  Quantity [" << existing.quantity << "]: ";
    std::getline(std::cin, input);
    if (!input.empty()) {
        try {
            int q = std::stoi(input);
            if (q >= 0) existing.quantity = q;
            else std::cout << "  [WARN] Invalid quantity kept unchanged.\n";
        } catch (...) {
            std::cout << "  [WARN] Invalid input, quantity unchanged.\n";
        }
    }

    /* Price */
    std::cout << "  Price [" << std::fixed << std::setprecision(2)
              << existing.price << "]: ";
    std::getline(std::cin, input);
    if (!input.empty()) {
        try {
            float p = std::stof(input);
            if (p >= 0.0f) existing.price = p;
            else std::cout << "  [WARN] Invalid price kept unchanged.\n";
        } catch (...) {
            std::cout << "  [WARN] Invalid input, price unchanged.\n";
        }
    }

    if (update_item(id, &existing)) {
        std::cout << "  [OK] Item updated successfully.\n";
    } else {
        std::cout << "  [ERROR] Update failed.\n";
    }
    pause();
}

/* ── Menu: Delete Item ───────────────────────────────────────── */
void InventoryManager::menuDeleteItem()
{
    std::cout << "  ── Delete Item ───────────────────────────\n";
    int id = readInt("  Enter item ID to delete", 1, std::numeric_limits<int>::max());

    Item probe;
    if (!get_item(id, &probe)) {
        std::cout << "  [ERROR] Item not found (ID=" << id << ").\n";
        pause(); return;
    }

    std::cout << "  About to delete:\n";
    printHeader(); printRow(probe); printDivider();
    std::cout << "  Confirm delete? (y/N): ";
    std::string confirm;
    std::getline(std::cin, confirm);

    if (!confirm.empty() && std::tolower(confirm[0]) == 'y') {
        if (delete_item(id)) {
            std::cout << "  [OK] Item soft-deleted.\n";
        } else {
            std::cout << "  [ERROR] Delete failed.\n";
        }
    } else {
        std::cout << "  [INFO] Delete cancelled.\n";
    }
    pause();
}

/* ── Menu: List All Items ────────────────────────────────────── */
void InventoryManager::menuListItems()
{
    std::cout << "  ── List All Items ────────────────────────\n";

    std::vector<Item> buf(MAX_BUFFER);
    int count = list_items(buf.data(), MAX_BUFFER);
    buf.resize(static_cast<size_t>(count));

    if (count == 0) {
        std::cout << "  No items found.\n";
        pause(); return;
    }

    /* Offer sort choice */
    std::cout << "  Sort by: (1) ID  (2) Name  [default=1]: ";
    std::string choice;
    std::getline(std::cin, choice);

    if (!choice.empty() && choice[0] == '2') {
        std::sort(buf.begin(), buf.end(), [](const Item &a, const Item &b) {
            return std::string(a.name) < std::string(b.name);
        });
        std::cout << "  (sorted by Name)\n";
    } else {
        std::sort(buf.begin(), buf.end(), [](const Item &a, const Item &b) {
            return a.id < b.id;
        });
        std::cout << "  (sorted by ID)\n";
    }

    std::cout << "\n";
    printHeader();
    for (const Item &item : buf) printRow(item);
    printDivider();
    std::cout << "  Total active items: " << count << "\n";
    pause();
}

/* ── Display helpers ─────────────────────────────────────────── */
void InventoryManager::printDivider()
{
    std::cout << "  +" << std::string(6,'-') << "+"
              << std::string(42,'-') << "+"
              << std::string(10,'-') << "+"
              << std::string(12,'-') << "+\n";
}

void InventoryManager::printHeader()
{
    printDivider();
    std::cout << "  |" << std::setw(6)  << std::left << " ID"
              << "|" << std::setw(42) << std::left << " Name"
              << "|" << std::setw(10) << std::left << " Qty"
              << "|" << std::setw(12) << std::left << " Price"
              << "|\n";
    printDivider();
}

void InventoryManager::printRow(const Item &item)
{
    std::cout << "  |" << std::setw(6)  << std::left << (" " + std::to_string(item.id))
              << "|" << std::setw(42) << std::left << (" " + std::string(item.name))
              << "|" << std::setw(10) << std::left << (" " + std::to_string(item.quantity))
              << "|" << std::setw(12) << std::left
                     << (" $" + [&]() -> std::string {
                             std::ostringstream oss;
                             oss << std::fixed << std::setprecision(2) << item.price;
                             return oss.str(); }())
              << "|\n";
}

void InventoryManager::printMenu()
{
    std::cout << "\n";
    std::cout << "  ╔══════════════════════════════════════╗\n";
    std::cout << "  ║     HYBRID INVENTORY MANAGER  v1.0   ║\n";
    std::cout << "  ╠══════════════════════════════════════╣\n";
    std::cout << "  ║  1. Add Item                         ║\n";
    std::cout << "  ║  2. View Item                        ║\n";
    std::cout << "  ║  3. Update Item                      ║\n";
    std::cout << "  ║  4. Delete Item                      ║\n";
    std::cout << "  ║  5. List All Items                   ║\n";
    std::cout << "  ║  6. Exit                             ║\n";
    std::cout << "  ╚══════════════════════════════════════╝\n";
}

/* ── Input helpers ───────────────────────────────────────────── */
void InventoryManager::clearInput()
{
    std::cin.clear();
    std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\n');
}

void InventoryManager::pause()
{
    std::cout << "\n  Press Enter to continue...";
    std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\n');
}

int InventoryManager::readInt(const std::string &prompt, int minVal, int maxVal)
{
    int val = 0;
    while (true) {
        std::cout << prompt << ": ";
        if (std::cin >> val) {
            clearInput();
            if (val >= minVal && val <= maxVal) return val;
            std::cout << "  [WARN] Enter a value between " << minVal
                      << " and " << maxVal << ".\n";
        } else {
            clearInput();
            std::cout << "  [WARN] Invalid input, please enter an integer.\n";
        }
    }
}

float InventoryManager::readFloat(const std::string &prompt, float minVal)
{
    float val = 0.0f;
    while (true) {
        std::cout << prompt << ": ";
        if (std::cin >> val) {
            clearInput();
            if (val >= minVal) return val;
            std::cout << "  [WARN] Value must be >= " << minVal << ".\n";
        } else {
            clearInput();
            std::cout << "  [WARN] Invalid input, please enter a number.\n";
        }
    }
}

std::string InventoryManager::readNonEmptyString(const std::string &prompt, int maxLen)
{
    std::string s;
    while (true) {
        std::cout << prompt << ": ";
        std::getline(std::cin, s);
        /* Trim leading/trailing spaces */
        size_t start = s.find_first_not_of(" \t");
        size_t end   = s.find_last_not_of(" \t");
        if (start == std::string::npos) {
            std::cout << "  [WARN] Name must not be empty.\n";
            continue;
        }
        s = s.substr(start, end - start + 1);
        if ((int)s.size() > maxLen) s = s.substr(0, maxLen);
        return s;
    }
}
CPP_EOF

cat > src/main.cpp << 'MAIN_EOF'
/* ============================================================
 * main.cpp  –  Program entry point
 * ============================================================ */
#include <iostream>
#include "InventoryManager.cpp"   /* single-TU build approach */

int main()
{
    InventoryManager mgr;
    mgr.run();
    return 0;
}
MAIN_EOF

cat > Makefile << 'MAKE_EOF'
# ============================================================
# Makefile – Hybrid Inventory Manager
# gcc  compiles the C backend
# g++  compiles the C++ frontend and links the final binary
# ============================================================

CC      = gcc
CXX     = g++
CFLAGS  = -Wall -Wextra -std=c11   -O2
CXXFLAGS= -Wall -Wextra -std=c++17 -O2

TARGET  = inventory_manager
OBJDIR  = build

C_SRCS  = src/inventory.c
CPP_SRCS= src/main.cpp

C_OBJS  = $(OBJDIR)/inventory.o
CPP_OBJS= $(OBJDIR)/main.o

.PHONY: all clean run

all: $(OBJDIR) $(TARGET)

$(OBJDIR):
	mkdir -p $(OBJDIR)

$(OBJDIR)/inventory.o: src/inventory.c include/inventory.h
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJDIR)/main.o: src/main.cpp include/inventory.h
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(TARGET): $(C_OBJS) $(CPP_OBJS)
	$(CXX) $(CXXFLAGS) $^ -o $@
	@echo "Build successful -> ./$(TARGET)"

run: all
	./$(TARGET)

clean:
	rm -rf $(OBJDIR) $(TARGET) inventory.dat
MAKE_EOF

cat > README.md << 'README_EOF'
# Hybrid Inventory Manager

A production-quality console application demonstrating a **hybrid C/C++ architecture**:

| Layer | Language | Role |
|-------|----------|------|
| Backend | C (C11) | Binary file I/O, data structures |
| Frontend | C++ (C++17) | Classes, STL, input validation, UI |

---

## Project Structure

```
hybrid_inventory_manager/
├── include/
│   └── inventory.h          # Shared header (extern "C" bridge)
├── src/
│   ├── inventory.c          # C backend – CRUD + binary file ops
│   ├── InventoryManager.cpp # C++ class – UI, validation, STL
│   └── main.cpp             # Entry point
├── Makefile
└── README.md
```

---

## Build Steps

### Prerequisites
- GCC ≥ 9 and G++ ≥ 9 (or any modern compiler supporting C11/C++17)
- GNU Make

### Compile
```bash
make
```
This produces the binary `./inventory_manager`.

### Run
```bash
./inventory_manager
# or shorthand:
make run
```

### Clean
```bash
make clean       # removes build/, binary, and inventory.dat
```

---

## Architecture Notes

- `include/inventory.h` declares the C API wrapped in `extern "C" { }` so the C++ layer can link to it without name-mangling.
- `src/inventory.c` uses **only** C features: `fopen`, `fread`, `fwrite`, `fseek`, raw structs.
- `src/InventoryManager.cpp` uses `std::vector`, `std::sort`, `std::string`, and I/O streams.
- Data is stored in `inventory.dat` as packed binary records. **The file persists between runs.**

---

## Menu Overview

```
╔══════════════════════════════════════╗
║     HYBRID INVENTORY MANAGER  v1.0   ║
╠══════════════════════════════════════╣
║  1. Add Item                         ║
║  2. View Item                        ║
║  3. Update Item                      ║
║  4. Delete Item                      ║
║  5. List All Items                   ║
║  6. Exit                             ║
╚══════════════════════════════════════╝
```

---

## 5 Test Cases

### Test 1 – Add items and verify persistence

```
Run 1:
  1 → Add Item | ID=1, Name=Widget A, Qty=50, Price=9.99
  1 → Add Item | ID=2, Name=Gadget B, Qty=20, Price=24.50
  6 → Exit

Run 2:
  5 → List All Items
Expected: Both items appear. (Proves binary persistence across restarts.)
```

---

### Test 2 – Reject duplicate ID

```
  1 → Add Item | ID=1, Name=Duplicate, Qty=10, Price=5.00
Expected output: [ERROR] An item with ID 1 already exists.
```

---

### Test 3 – Soft delete and verify invisibility

```
  4 → Delete Item | ID=2 → confirm 'y'
  5 → List All Items
Expected: Only ID=1 (Widget A) is visible. Gadget B is hidden.
  2 → View Item | ID=2
Expected: [ERROR] Item not found (ID=2).
```

---

### Test 4 – In-place update

```
  3 → Update Item | ID=1
  New Qty=99, New Price=12.99  (press Enter to keep Name)
  2 → View Item | ID=1
Expected: Qty=99, Price=$12.99, Name=Widget A (unchanged).
```

---

### Test 5 – Input validation (no crash)

```
  Enter choice: abc       → [WARN] Invalid input, please enter an integer.
  1 → Add Item
  ID: -5                  → [WARN] Enter a value between 1 and 2147483647.
  ID: 0                   → [WARN] same
  Name: (blank Enter)     → [WARN] Name must not be empty.
  Qty: -1                 → [WARN] Enter a value between 0 and ...
  Price: -3.5             → [WARN] Value must be >= 0.
Expected: No crash at any step.
```

---

## Sample Output

```
  ╔══════════════════════════════════════╗
  ║     HYBRID INVENTORY MANAGER  v1.0   ║
  ╚══════════════════════════════════════╝

  ── List All Items ────────────────────────
  (sorted by ID)

  +------+------------------------------------------+----------+------------+
  | ID   | Name                                     | Qty      | Price      |
  +------+------------------------------------------+----------+------------+
  | 1    | Widget A                                 | 50       | $9.99      |
  | 3    | Sprocket C                               | 100      | $3.50      |
  | 5    | Capacitor X                              | 200      | $0.75      |
  +------+------------------------------------------+----------+------------+
  Total active items: 3
```

---

## Error Handling Summary

| Scenario | Behaviour |
|----------|-----------|
| `inventory.dat` missing | `fopen` with `"rb"` returns NULL; add/list gracefully return 0/empty |
| Duplicate ID | Checked via full file scan before appending |
| Negative ID/Qty/Price | Rejected by C++ input loop before reaching C layer |
| Empty name | Rejected by C++ `readNonEmptyString` helper |
| Non-integer input | `std::cin` failure caught; stream cleared and re-prompted |
| Corrupted record | Partial reads fall through; only complete records processed |
README_EOF

echo ""
echo "Done! Project created in: hybrid_inventory_manager/"
echo ""
echo "To build and run:"
echo "  cd hybrid_inventory_manager"
echo "  make"
echo "  ./inventory_manager"
