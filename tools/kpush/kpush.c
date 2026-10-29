// kpush: copy files into a Kindle folder over MTP in ONE session.
// v3: no USB reset on close; walks folders by listing (works uncached).
// usage: kpush /path/on/kindle file1 [file2 ...]   (creates missing folders; never deletes)
#include <libmtp.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <libgen.h>
#include <sys/stat.h>

/* Mirror of libmtp 1.1.23 internal struct _PTP_USB (src/libusb-glue.h, libusb1
 * build) so we can clear the reset flag that libmtp re-adds after open when the
 * device advertises the android.com MTP extension. Only valid for 1.1.23. */
typedef struct {
  void *params; void *handle;
  uint8_t config, interface, altsetting;
  int inep, inep_maxpacket, outep, outep_maxpacket, intep;
  int callback_active, timeout;
  uint16_t bcdusb;
  uint64_t current_transfer_total, current_transfer_complete;
  LIBMTP_progressfunc_t current_transfer_callback;
  void const *current_transfer_callback_data;
  LIBMTP_raw_device_t rawdevice;
} kpush_ptp_usb_mirror;
#define KINDLE_VID 0x1949
#define COLORSOFT1_PID 0x9981 /* Kindle Colorsoft 1st gen; libmtp mislabels it */
#define KP_RESET_FLAG ((uint32_t)0x10000000) /* DEVICE_FLAG_FORCE_RESET_ON_CLOSE */
/* struct mirror verified only against libmtp 1.1.23 headers; checked at startup */
static int no_reset_on_close(LIBMTP_mtpdevice_t *d){
  kpush_ptp_usb_mirror *u=(kpush_ptp_usb_mirror*)d->usbinfo;
  if(u->rawdevice.device_entry.vendor_id!=KINDLE_VID || u->rawdevice.device_entry.product_id!=COLORSOFT1_PID){fprintf(stderr,"layout check failed, not touching device\n");return -1;}
  u->rawdevice.device_entry.device_flags &= ~KP_RESET_FLAG;
  printf("reset-on-close: %s (vid %04x pid %04x)\n",
    (u->rawdevice.device_entry.device_flags & KP_RESET_FLAG)?"STILL ON":"off",
    u->rawdevice.device_entry.vendor_id, u->rawdevice.device_entry.product_id);
  return 0;
}
int main(int argc,char**argv){
  if(strcmp(LIBMTP_VERSION_STRING,"1.1.23")){fprintf(stderr,"built for libmtp 1.1.23 only, found %s\n",LIBMTP_VERSION_STRING);return 6;}
  int check_only = argc==2 && !strcmp(argv[1],"--check");
  if(argc<3 && !check_only){fprintf(stderr,"usage: kpush /kindle/folder files...\n       kpush --check   (connect, identify, disconnect; writes nothing)\n");return 2;}
  LIBMTP_Init();
  // Open the Kindle without libmtp's reset-on-close. libmtp lists Amazon
  // 1949:9981 with DEVICE_FLAGS_ANDROID_BUGS, which includes
  // DEVICE_FLAG_FORCE_RESET_ON_CLOSE: libusb_reset_device() on release, which
  // makes the Kindle drop off USB and re-enumerate. Clear that one flag.
  LIBMTP_raw_device_t *raw=NULL; int nraw=0;
  if(LIBMTP_Detect_Raw_Devices(&raw,&nraw)!=LIBMTP_ERROR_NONE||nraw<1){fprintf(stderr,"no device\n");return 3;}
  // Match the Kindle Colorsoft (1st gen) by USB ID, not by libmtp's name for
  // it. libmtp 1.1.23 labels 1949:9981 "Kindle Scribe 32GB"; that label is
  // wrong for this device and is never used here.
  int k=-1;
  for(int i=0;i<nraw;i++) if(raw[i].device_entry.vendor_id==KINDLE_VID && raw[i].device_entry.product_id==COLORSOFT1_PID){k=i;break;}
  if(k<0){fprintf(stderr,"no Kindle Colorsoft (1949:9981) found; %d other MTP device(s) ignored\n",nraw);return 3;}
  if(k) raw[0]=raw[k];
  printf("found Kindle Colorsoft (1st gen), USB 1949:9981, bus %u dev %u\n",raw[0].bus_location,raw[0].devnum);
  raw[0].device_entry.device_flags &= ~((uint32_t)0x10000000); /* DEVICE_FLAG_FORCE_RESET_ON_CLOSE */
  printf("device flags 0x%08x (reset-on-close %s)\n",raw[0].device_entry.device_flags,
         (raw[0].device_entry.device_flags & 0x10000000)?"ON":"off");
  LIBMTP_mtpdevice_t *d=LIBMTP_Open_Raw_Device_Uncached(&raw[0]);
  if(!d){fprintf(stderr,"could not open device\n");return 3;}
  if(no_reset_on_close(d)){LIBMTP_Release_Device(d);return 5;}
  { char *m=LIBMTP_Get_Modelname(d); printf("device reports model: %s\n",m?m:"(none)"); free(m); }
  if(check_only){ no_reset_on_close(d); LIBMTP_Release_Device(d); printf("check done, nothing written\n"); return 0; }
  LIBMTP_Get_Storage(d,LIBMTP_STORAGE_SORTBY_NOTSORTED);
  uint32_t storage=d->storage?d->storage->id:0;
  // Walk the path one level at a time by listing each folder on the device.
  // (The device is opened uncached, so LIBMTP_Get_Folder_List() has no tree.)
  char path[1024]; strncpy(path,argv[1],sizeof path-1); path[sizeof path-1]=0;
  uint32_t parent=LIBMTP_FILES_AND_FOLDERS_ROOT; int depth=0; char *save=NULL;
  for(char *p=strtok_r(path,"/",&save);p;p=strtok_r(NULL,"/",&save),depth++){
    uint32_t id=0;
    LIBMTP_file_t *ls=LIBMTP_Get_Files_And_Folders(d,storage,parent);
    for(LIBMTP_file_t *f=ls;f;f=f->next) if(!id && f->filetype==LIBMTP_FILETYPE_FOLDER && strcmp(f->filename,p)==0) id=f->item_id;
    while(ls){LIBMTP_file_t *n=ls->next; LIBMTP_destroy_file_t(ls); ls=n;}
    if(!id){
      if(depth==0){fprintf(stderr,"top-level folder %s not found on the Kindle; refusing to create folders at the root\n",p);
        no_reset_on_close(d);LIBMTP_Release_Device(d);return 4;}
      char *nm=strdup(p); id=LIBMTP_Create_Folder(d,nm,parent,storage); free(nm);
      if(!id){fprintf(stderr,"mkdir %s failed\n",p);LIBMTP_Dump_Errorstack(d);no_reset_on_close(d);LIBMTP_Release_Device(d);return 4;}
      printf("created %s (%u)\n",p,id);
    }
    parent=id;
  }
  if(parent==LIBMTP_FILES_AND_FOLDERS_ROOT){fprintf(stderr,"refusing to copy into the Kindle's root\n");no_reset_on_close(d);LIBMTP_Release_Device(d);return 4;}
  printf("target folder id %u\n",parent);
  // existing files in target, to replace same-named ones
  LIBMTP_file_t *files=LIBMTP_Get_Files_And_Folders(d,storage,parent);
  int fail=0;
  for(int i=2;i<argc;i++){
    struct stat st; if(stat(argv[i],&st)){perror(argv[i]);fail++;continue;}
    char *tmp=strdup(argv[i]); char *bn=basename(tmp);
    for(LIBMTP_file_t *f=files;f;f=f->next) if(f->filetype!=LIBMTP_FILETYPE_FOLDER && strcmp(f->filename,bn)==0){
      if(LIBMTP_Delete_Object(d,f->item_id)==0) printf("replaced old %s\n",bn); }
    LIBMTP_file_t *nf=LIBMTP_new_file_t();
    nf->filename=strdup(bn); nf->filesize=st.st_size; nf->filetype=LIBMTP_FILETYPE_UNKNOWN;
    nf->parent_id=parent; nf->storage_id=storage;
    int r=LIBMTP_Send_File_From_File(d,argv[i],nf,NULL,NULL);
    printf("%s %s (%lld bytes)\n",r==0?"sent":"FAILED",bn,(long long)st.st_size);
    if(r){LIBMTP_Dump_Errorstack(d);LIBMTP_Clear_Errorstack(d);fail++;}
    LIBMTP_destroy_file_t(nf); free(tmp);
  }
  // verify
  LIBMTP_file_t *after=LIBMTP_Get_Files_And_Folders(d,storage,parent);
  for(LIBMTP_file_t *f=after;f;f=f->next) printf("on kindle: %s %llu\n",f->filename,(unsigned long long)f->filesize);
  no_reset_on_close(d); /* again, right before close */
  LIBMTP_Release_Device(d);
  return fail?1:0;
}
