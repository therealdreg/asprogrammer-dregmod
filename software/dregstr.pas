unit dregstr;

{
  Translatable text for the parts of the interface this fork added.

  By Dreg
  https://github.com/therealdreg/asprogrammer-dregmod

  Deliberately a separate unit rather than additions to msgstr.pas. That file is
  still byte for byte identical to upstream, and keeping it that way means an
  upstream change to it merges without a conflict. See FORK-CHANGES.md.

  These are resourcestrings, not constants, because that is the only mechanism
  that reaches them: Translations.TranslateResourceStrings rewrites the
  resourcestring table when the language changes. The other mechanism this
  program uses, TPOTranslator.UpdateTranslation, only walks the published
  properties of a form, so it cannot touch a string built in code, and it cannot
  touch the dialogs built with TForm.CreateNew either, because those are not
  components of MainForm.

  Two of the strings below matter more than they look. The COM port menu caption
  is rewritten from code on every refresh tick, so a .po entry for that menu item
  is overwritten a moment later and the caption has to come from here instead.

  What is NOT here, on purpose: the protocol diagnostics in buzzpirathw.pas and
  buspirate5hw.pas. Those are for whoever is debugging a link, and translating
  them makes a bug report harder to read, not easier. The same goes for the
  field labels of the device report, the hexadecimal header of the I2C grid, and
  the tokens written into settings.xml, which would break saved settings if a
  translation changed them.
}

{$mode objfpc}{$H+}

interface

resourcestring
  //--- COM port menus ---------------------------------------------------------
  STR_DM_NO_SERIAL_PORTS   = 'no serial ports found - plug the device in';
  STR_DM_COMPORT_NONE      = 'COM port: none selected';
  STR_DM_COMPORT_PREFIX    = 'COM port: ';
  STR_DM_NOT_THIS_ONE      = ' - not this one';

  //--- I2C bus scanner --------------------------------------------------------
  STR_DM_I2C_SCAN_TITLE    = 'I2C bus scan';
  STR_DM_I2C_SCAN_NO_RUN   = 'The scan could not run.';
  STR_DM_I2C_SCAN_ON       = 'I2C bus scan on ';
  STR_DM_I2C_SCAN_COUNT    = '%d device(s) answered.';
  STR_DM_I2C_USE_ADDRESS   = 'Use this address';
  STR_DM_I2C_ADDR_STORED   = 'Address stored. It takes effect once an I2C chip ' +
                             'is selected - that is when the address toggles appear.';

  //--- hex editor random fill -------------------------------------------------
  STR_DM_FILL_TITLE        = 'Fill with random data';
  STR_DM_FILL_NO_SIZE      = 'Pick a chip first, or read one / open a file, so ' +
                             'there is a size to fill.';

  //--- status register editor -------------------------------------------------
  STR_DM_SREG_NO_ANSWER    = 'The chip did not answer when its status register ' +
                             'was read, so nothing below reflects it.';

  //--- chip menu --------------------------------------------------------------
  //The token at the end changes with the chip family, so it is a placeholder
  //rather than something the code chops off the end of a translated caption.
  STR_DM_SKIP_TOKEN        = 'Do not write %s';

  //--- write protection ---------------------------------------------------------
  //A protected chip accepts an erase and a program without complaint and keeps
  //its old contents, so the operation used to finish on "Done" having done
  //nothing at all. The protection bits are not read the same way by every
  //family, so this warns rather than refusing to run.
  STR_DM_MAYBE_PROTECTED   = 'The chip reported write protection before this ' +
                             'ran, so it may have kept its old contents. Use ' +
                             'Verify to be sure, and Unprotect if it did.';

  //--- shared dialog buttons --------------------------------------------------
  STR_DM_BTN_CLOSE         = 'Close';
  STR_DM_BTN_COPY          = 'Copy';

implementation

end.
