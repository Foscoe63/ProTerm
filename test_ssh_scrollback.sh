#!/bin/bash

# Test script to verify SSH scrollback functionality
# This script will generate multiple pages of output to test pagination and scrollback

echo "Testing SSH scrollback functionality..."
echo "This script will generate multiple pages of output to test pagination and scrollback."
echo ""

# Generate a large amount of output to simulate "show run" on ASA
for i in {1..50}; do
    echo "interface GigabitEthernet0/$i"
    echo " description Test interface $i"
    echo " nameif inside"
    echo " security-level 100"
    echo " ip address 192.168.$i.1 255.255.255.0"
    echo "!"
    echo ""

    # Add pagination prompt every 20 lines (simulating ASA behavior)
    if (( i % 20 == 0 )) && (( i < 50 )); then
        echo "<--- More --->"
        # In a real ASA, this would wait for user input
        # For testing, we'll just continue
        sleep 1
    fi
done

echo "access-list outside_in extended permit tcp any any eq 80"
echo "access-list outside_in extended permit tcp any any eq 443"
echo "!"
echo ""
echo "crypto map outside_map 1 match address outside_in"
echo "crypto map outside_map 1 set peer 1.2.3.4"
echo "crypto map outside_map 1 set ikev1 transform-set ESP-AES-128-SHA"
echo "crypto map outside_map interface outside"
echo "!"
echo ""
echo "ASA5506-X#"

echo ""
echo "Test completed. You should be able to scroll back through all the output above."
