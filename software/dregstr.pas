unit dregstr;

{
  Translatable text for the parts of the interface this fork added.

  By Dreg
  https://github.com/therealdreg/asprogrammer-dregmod

  A separate unit, so that msgstr.pas stays byte for byte identical to upstream
  and an upstream change to it merges without a conflict.

  These are resourcestrings because text built in code is translated only by
  Translations.TranslateResourceStrings, which rewrites the resourcestring
  table when a language is loaded. The other mechanism this program uses,
  TPOTranslator.UpdateTranslation, walks the published properties of a form
  and its components, so it cannot translate a string built in code, nor the
  dialogs built with TForm.CreateNew, which are not components of MainForm.

  The COM port menu captions are built in code when the port list or the
  selection changes, and ChangeLang rebuilds them after UpdateTranslation, so
  a .po entry for those menu items is overwritten and their text has to come
  from here.

  What is not here, on purpose: the protocol diagnostics in buzzpirathw.pas and
  buspirate5hw.pas. Those are for whoever is debugging a link, and translating
  them makes a bug report harder to read. The same goes for the field labels of
  the device report, the hexadecimal header of the I2C grid, and the tokens
  written into settings.xml, which would break saved settings if a translation
  changed them.
}

{$mode objfpc}{$H+}

interface

resourcestring
  //COM port menus
  STR_DM_NO_SERIAL_PORTS   = 'no serial ports found - plug the device in';
  STR_DM_COMPORT_NONE      = 'COM port: none selected';
  STR_DM_COMPORT_PREFIX    = 'COM port: ';
  STR_DM_NOT_THIS_ONE      = ' - not this one';

  //I2C bus scanner
  STR_DM_I2C_SCAN_TITLE    = 'I2C bus scan';
  STR_DM_I2C_SCAN_NO_RUN   = 'The scan could not run.';
  STR_DM_I2C_SCAN_ON       = 'I2C bus scan on ';
  STR_DM_I2C_SCAN_COUNT    = '%d device(s) answered.';
  STR_DM_I2C_USE_ADDRESS   = 'Use this address';
  STR_DM_I2C_ADDR_STORED   = 'Address stored. It takes effect once the I2C bus ' +
                             'is picked, which is when the address toggles appear.';

  //I2C write and erase
  //The two %d are the pages that failed and the pages sent. The %s is the
  //address of the first failed page, in hex. A chip with its WP pin high, or a
  //protected area, can refuse the data bytes, which a programmer that sees
  //acknowledges reports as a failed page.
  STR_DM_I2C_PAGES_FAILED  = '%d of %d pages failed, the first at 0x%s. The ' +
                             'write protect pin (WP) may be high, or the chip ' +
                             'may protect that area (an SPD EEPROM can protect ' +
                             '00h-7Fh).';

  //Hex editor random fill
  STR_DM_FILL_TITLE        = 'Fill with random data';
  STR_DM_FILL_NO_SIZE      = 'Pick a chip first, or read one / open a file, so ' +
                             'there is a size to fill.';
  //The %d is the number of bytes the fill replaces.
  STR_DM_FILL_ASK          = 'Replace the whole %d byte hexeditor content with ' +
                             'random data?';
  //The %s is the Program IC button's tooltip in the language shown, since the
  //button itself has only an icon.
  STR_DM_FILL_UNTOUCHED    = 'The chip itself is not touched until you press ' +
                             '%s.';

  //Status register reads
  STR_DM_SREG_NO_ANSWER    = 'The status register could not be read: the ' +
                             'transfer through the programmer failed.';

  //Options menu, SPI submenu
  //The token changes with the chip family, 00 on the KB9012 and FF on the
  //others, so it is a placeholder that a translation can put anywhere.
  STR_DM_SKIP_TOKEN        = 'Do not write %s';

  //Erase
  STR_DM_ERASE_NOT_SENT    = 'The programmer could not send the erase command ' +
                             'to the chip.';

  //Write protection
  //A protected chip accepts an erase and a program without complaint and keeps
  //its old contents, so without this the operation finishes on "Done" having
  //done nothing. The protection bits are not read the same way by every
  //family, so this warns rather than refusing to run.
  STR_DM_MAYBE_PROTECTED   = 'The chip reported write protection before this ' +
                             'ran, so it may have kept its old contents. Use ' +
                             'Verify to be sure, and Unprotect if it did.';

  //Four byte addressing
  STR_DM_EN4B_FAILED       = 'EN4B (four byte address mode) could not be sent, ' +
                             'so the operation stops: a chip left in three byte ' +
                             'mode would take every address it sends wrongly.';

  //Microwire
  STR_DM_MW_INIT_FAILED    = 'Microwire could not be started on this programmer';

  //Bus Pirate v5+
  //Shown at exit when the device could not be parked with the supply off: the
  //log that said so goes away with the window.
  STR_DM_BP5_SUPPLY_LEFT_ON = 'The Bus Pirate may still be powering the target: ' +
                              'the last session ended without switching the ' +
                              'supply off. Unplug the Bus Pirate to be sure.';

  //Settings
  //Shown at close when settings.xml could not be written; %s is why.
  STR_DM_SETTINGS_NOT_SAVED = 'The settings could not be saved: %s';

  //Buttons of the report windows
  STR_DM_BTN_CLOSE         = 'Close';
  STR_DM_BTN_COPY          = 'Copy';

implementation

end.
