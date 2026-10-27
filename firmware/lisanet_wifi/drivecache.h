// drivecache -- the floppy images ESFloppy's drive will take, read once in the background and kept, so the web page's
// Insert a disk dialog fills at once. Written with an AI assistant.
//
// In Normal mode nothing can change ESFloppy's card (uploads, renames and deletes happen only while its files are being
// managed), so the list stays good until the drives leave Normal -- then it is thrown away and read again once they are
// back and ESFloppy's drive firmware answers. It is also thrown away when the drive type changes (Sony / Twiggy:
// ESFloppy accepts different images), and on Rescan. The walk matches the page's old one: hidden names skipped, four
// folder levels deep, ESFloppy's own filter on each folder (sdlink::driveList). One folder per step, and only while the
// Lisa's FujiNet has been quiet a few seconds, since everything here runs on one task.
#pragma once
#include <Arduino.h>

namespace drivecache {

void poll();                      // call from loop(): takes the next folder when it is a good moment
void noteMode(uint8_t espMode);   // from any fresh FPGA status: 0 Normal, 1/2 a card's files being managed
void noteDriveType(uint8_t emulMode, bool twiggy);   // from a drive status reply
void rescan();                    // forget the list and read the card again
String json();                    // {"state":"ready|scanning|waiting|off","folders":n,"images":[{"p":path,"s":size},...]}

}  // namespace drivecache
