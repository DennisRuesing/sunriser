
function download_and_install_firmware(firmware_url) {
  $('#blockertext').html('Lade neue Firmware aus dem Internet');
  $('body').addClass('screenblocker');
  var call_options = {
    type: 'GET',
    url: firmware_url,
    contentType: 'application/octet-stream',
    dataType: 'arraybuffer',
    processData: false,
    cache: false,
    error: function (xhr, ajaxOptions, thrownError) {
      sr_error();
    },
    success: function (bytesarray) {
      install_firmware(bytesarray);
    }
  };
  $.ajax(call_options);
}

function install_firmware(bytesarray) {
  sr_screenblock('Sende neue Firmware an SunRiser');
  var call_options = {
    type: 'PUT',
    url: '/firmware',
    data: bytesarray,
    contentType: 'application/octet-stream',
    dataType: 'arraybuffer',
    processData: false,
    cache: false,
    error: function(xhr,error,errorthrown){
      sr_error();
    },
    success: function(data,status,xhr){
      sr_screenblock('<div>Warte auf Neustart</div><div>Bitte das Ger&auml;t NICHT abschalten!!!</div><div>(ca. 1 Minute)</div>');
      wait_for_sunriser(window.location.href.replace('firmware','upgraded'));
    },
  };
  $.ajax(call_options);
}
