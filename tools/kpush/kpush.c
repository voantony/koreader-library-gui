// kpush v6: v5's push, unchanged, plus read-only `ls` and `pull`.
//   kpush.v6 [push] /kindle/folder file1 [file2 ...]   push (same as v5)
//   kpush.v6 ls [/kindle/path]                         list a folder (default /)
//   kpush.v6 pull [--open] [--overwrite] /kindle/path [mac_dest_dir]
//   kpush.v6 check                                     connect, identify, write nothing
//   kpush.v6 --help
// No delete, rename or move command exists. Only push replaces a same-named file
// in the target folder, exactly as v5 did (via safe_delete).
// All output (ours and libmtp's) passes through a filter that redacts anything
// looking like a Kindle serial (G followed by 3+ of [0-9A-Z]).
// Never resets USB: clears libmtp's FORCE_RESET_ON_CLOSE flag like v5.
// If the device can't be opened (busy: Calibre etc.), it stops; no retries.
#include <libmtp.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <libgen.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <poll.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>

/* ---------- serial-redacting output filter ---------- */
static pid_t filt_pid=-1;
static void wr(int fd,const char *s,size_t n){ while(n){ ssize_t w=write(fd,s,n); if(w<=0){ if(errno==EINTR) continue; return;} s+=w; n-=(size_t)w; } }
static int isserialch(char c){ return (c>='0'&&c<='9')||(c>='A'&&c<='Z'); }
static void redact_out(int fd,const char *s,size_t n){
  static const char rep[]="GR\xe2\x80\xa6(redacted)";
  size_t i=0,st=0;
  while(i<n){
    if(s[i]=='G'){ size_t j=i+1; while(j<n && isserialch(s[j])) j++;
      if(j-i-1>=3){ wr(fd,s+st,i-st); wr(fd,rep,sizeof rep-1); i=j; st=j; continue; } }
    i++;
  }
  wr(fd,s+st,n-st);
}
typedef struct { int in,out; char buf[65536]; size_t len; int open; } fstream;
static void fs_flush_lines(fstream *f,int all){
  size_t start=0;
  for(size_t i=0;i<f->len;i++) if(f->buf[i]=='\n'){ redact_out(f->out,f->buf+start,i+1-start); start=i+1; }
  if(all || (start==0 && f->len==sizeof f->buf)){ redact_out(f->out,f->buf+start,f->len-start); start=f->len; }
  memmove(f->buf,f->buf+start,f->len-start); f->len-=start;
}
static void filter_child(int r1,int o1,int r2,int o2){
  signal(SIGINT,SIG_IGN); signal(SIGPIPE,SIG_IGN);
  static fstream s[2]; s[0].in=r1; s[0].out=o1; s[0].open=1; s[1].in=r2; s[1].out=o2; s[1].open=1;
  while(s[0].open||s[1].open){
    struct pollfd p[2]; int np=0, map[2];
    for(int k=0;k<2;k++) if(s[k].open){ p[np].fd=s[k].in; p[np].events=POLLIN; map[np]=k; np++; }
    if(poll(p,np,-1)<0){ if(errno==EINTR) continue; break; }
    for(int q=0;q<np;q++) if(p[q].revents){
      fstream *f=&s[map[q]];
      ssize_t r=read(f->in,f->buf+f->len,sizeof f->buf-f->len);
      if(r<=0){ if(r<0&&errno==EINTR) continue; fs_flush_lines(f,1); f->open=0; continue; }
      f->len+=(size_t)r; fs_flush_lines(f,0);
    }
  }
  _exit(0);
}
static void filter_finish(void){
  if(filt_pid<=0) return;
  fflush(stdout); fflush(stderr);
  int dn=open("/dev/null",1); dup2(dn,1); dup2(dn,2); close(dn);
  int st; waitpid(filt_pid,&st,0); filt_pid=-1;
}
static void filter_start(void){
  int a[2],b[2]; if(pipe(a)||pipe(b)) return;
  int o1=dup(1), o2=dup(2);
  pid_t p=fork(); if(p<0) return;
  if(p==0){ close(a[1]); close(b[1]); filter_child(a[0],o1,b[0],o2); }
  close(a[0]); close(b[0]); close(o1); close(o2);
  dup2(a[1],1); dup2(b[1],2); close(a[1]); close(b[1]);
  setvbuf(stdout,NULL,_IOLBF,0); setvbuf(stderr,NULL,_IONBF,0);
  filt_pid=p; atexit(filter_finish);
}

/* ---------- from v5, unchanged ---------- */
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
#define COLORSOFT1_PID 0x9981
#define KP_RESET_FLAG ((uint32_t)0x10000000)
static int no_reset_on_close(LIBMTP_mtpdevice_t *d){
  kpush_ptp_usb_mirror *u=(kpush_ptp_usb_mirror*)d->usbinfo;
  if(u->rawdevice.device_entry.vendor_id!=KINDLE_VID || u->rawdevice.device_entry.product_id!=COLORSOFT1_PID){fprintf(stderr,"layout check failed, not touching device\n");return -1;}
  u->rawdevice.device_entry.device_flags &= ~KP_RESET_FLAG;
  printf("reset-on-close: %s (vid %04x pid %04x)\n",
    (u->rawdevice.device_entry.device_flags & KP_RESET_FLAG)?"STILL ON":"off",
    u->rawdevice.device_entry.vendor_id, u->rawdevice.device_entry.product_id);
  return 0;
}
/* The only delete path; used only by push to replace a same-named file, as in v5. */
static int safe_delete(LIBMTP_mtpdevice_t *d,uint32_t id,uint32_t parent){
  if(id==0 || id==0xFFFFFFFFu || id==LIBMTP_FILES_AND_FOLDERS_ROOT || id==parent){
    fprintf(stderr,"REFUSING delete of object id 0x%08x\n",id); abort(); }
  return LIBMTP_Delete_Object(d,id);
}
static void free_list(LIBMTP_file_t *ls){ while(ls){LIBMTP_file_t *n=ls->next; LIBMTP_destroy_file_t(ls); ls=n;} }

/* ---------- v6 read-only helpers ---------- */
static void human(uint64_t n,char *o,size_t on){
  const char *u[]={"B","KB","MB","GB"}; double v=(double)n; int i=0;
  while(v>=1024 && i<3){ v/=1024; i++; }
  if(i==0) snprintf(o,on,"%llu B",(unsigned long long)n); else snprintf(o,on,"%.1f %s",v,u[i]);
}
static int safe_name(const char *n){ return n && *n && strcmp(n,".") && strcmp(n,"..") && !strchr(n,'/'); }
/* Resolve a Kindle path. Root -> *id=ROOT, *isdir=1. Returns 0 ok, 4 not found. */
static int resolve(LIBMTP_mtpdevice_t *d,uint32_t storage,const char *p0,uint32_t *id,int *isdir,uint64_t *size,char *name,size_t nn){
  char path[1024]; strncpy(path,p0,sizeof path-1); path[sizeof path-1]=0;
  uint32_t cur=LIBMTP_FILES_AND_FOLDERS_ROOT; int cdir=1; uint64_t csz=0; char *save=NULL;
  snprintf(name,nn,"/");
  for(char *p=strtok_r(path,"/",&save);p;p=strtok_r(NULL,"/",&save)){
    if(!cdir){fprintf(stderr,"%s is a file, not a folder\n",name);return 4;}
    uint32_t found=0; int fdir=0; uint64_t fsz=0;
    LIBMTP_file_t *ls=LIBMTP_Get_Files_And_Folders(d,storage,cur);
    for(LIBMTP_file_t *f=ls;f;f=f->next) if(f->filename && !strcmp(f->filename,p)){
      int isd=f->filetype==LIBMTP_FILETYPE_FOLDER;
      if(!found || (isd && !fdir)){ found=f->item_id; fdir=isd; fsz=f->filesize; }
    }
    free_list(ls);
    if(!found){fprintf(stderr,"%s not found on the Kindle\n",p);return 4;}
    cur=found; cdir=fdir; csz=fsz; snprintf(name,nn,"%s",p);
  }
  *id=cur; *isdir=cdir; *size=csz; return 0;
}
static int cmp_ent(const void *a,const void *b){
  LIBMTP_file_t *x=*(LIBMTP_file_t*const*)a, *y=*(LIBMTP_file_t*const*)b;
  int dx=x->filetype==LIBMTP_FILETYPE_FOLDER, dy=y->filetype==LIBMTP_FILETYPE_FOLDER;
  if(dx!=dy) return dy-dx;
  return strcasecmp(x->filename?x->filename:"",y->filename?y->filename:"");
}
static void print_entry(LIBMTP_file_t *f){
  char tb[32]="-"; if(f->modificationdate){ time_t t=f->modificationdate; strftime(tb,sizeof tb,"%Y-%m-%d %H:%M",localtime(&t)); }
  if(f->filetype==LIBMTP_FILETYPE_FOLDER) printf("dir  %12s  %-16s  %s/\n","-",tb,f->filename);
  else printf("file %12llu  %-16s  %s\n",(unsigned long long)f->filesize,tb,f->filename);
}
static int do_ls(LIBMTP_mtpdevice_t *d,uint32_t storage,const char *path){
  uint32_t id; int isdir; uint64_t sz; char nm[512];
  if(resolve(d,storage,path,&id,&isdir,&sz,nm,sizeof nm)) return 4;
  printf("listing %s\n",path);
  if(!isdir){
    /* show the single file's entry from its parent listing */
    char pp[1024]; strncpy(pp,path,sizeof pp-1); pp[sizeof pp-1]=0; char *sl=strrchr(pp,'/'); if(sl) *sl=0;
    uint32_t pid; int pd; uint64_t ps; char pn[512];
    if(resolve(d,storage,*pp?pp:"/",&pid,&pd,&ps,pn,sizeof pn)) return 4;
    LIBMTP_file_t *ls=LIBMTP_Get_Files_And_Folders(d,storage,pid);
    for(LIBMTP_file_t *f=ls;f;f=f->next) if(f->item_id==id) print_entry(f);
    free_list(ls); return 0;
  }
  LIBMTP_file_t *ls=LIBMTP_Get_Files_And_Folders(d,storage,id);
  int n=0; for(LIBMTP_file_t *f=ls;f;f=f->next) n++;
  LIBMTP_file_t **arr=calloc(n?n:1,sizeof *arr); int i=0; for(LIBMTP_file_t *f=ls;f;f=f->next) arr[i++]=f;
  qsort(arr,n,sizeof *arr,cmp_ent);
  int nd=0,nf=0; uint64_t tot=0;
  for(i=0;i<n;i++){ print_entry(arr[i]); if(arr[i]->filetype==LIBMTP_FILETYPE_FOLDER) nd++; else { nf++; tot+=arr[i]->filesize; } }
  char h[32]; human(tot,h,sizeof h);
  printf("%d folder(s), %d file(s), %llu bytes (%s) in files\n",nd,nf,(unsigned long long)tot,h);
  free(arr); free_list(ls); return 0;
}
static int mkdir_p(const char *p){
  char b[2048]; strncpy(b,p,sizeof b-1); b[sizeof b-1]=0;
  for(char *s=b+1;*s;s++) if(*s=='/'){ *s=0; if(mkdir(b,0755) && errno!=EEXIST) return -1; *s='/'; }
  if(mkdir(b,0755) && errno!=EEXIST) return -1;
  struct stat st; return (stat(b,&st)==0 && S_ISDIR(st.st_mode))?0:-1;
}
typedef struct { int files,failed,skipped; uint64_t bytes; int overwrite; } pullstat;
static void pull_file(LIBMTP_mtpdevice_t *d,uint32_t id,uint64_t size,const char *out,const char *rel,pullstat *ps){
  struct stat st;
  if(!ps->overwrite && lstat(out,&st)==0){ printf("skip %s (already on Mac; use --overwrite)\n",rel); ps->skipped++; return; }
  char tmp[2100]; snprintf(tmp,sizeof tmp,"%s.kpullpart",out);
  int r=LIBMTP_Get_File_To_File(d,id,tmp,NULL,NULL);
  if(r){ LIBMTP_Dump_Errorstack(d); LIBMTP_Clear_Errorstack(d); unlink(tmp); printf("file %s %llu READ-FAILED\n",rel,(unsigned long long)size); ps->failed++; return; }
  if(stat(tmp,&st) || (uint64_t)st.st_size!=size){ printf("file %s size mismatch (Mac %lld, Kindle %llu) FAILED\n",rel,(long long)st.st_size,(unsigned long long)size); unlink(tmp); ps->failed++; return; }
  if(rename(tmp,out)){ perror(out); unlink(tmp); ps->failed++; return; }
  printf("file %s %llu copied\n",rel,(unsigned long long)size); ps->files++; ps->bytes+=size;
}
static void pull_tree(LIBMTP_mtpdevice_t *d,uint32_t storage,uint32_t folder,const char *local,const char *rel,pullstat *ps){
  if(mkdir_p(local)){ fprintf(stderr,"cannot create %s\n",local); ps->failed++; return; }
  printf("dir  %s/\n",rel);
  LIBMTP_file_t *ls=LIBMTP_Get_Files_And_Folders(d,storage,folder);
  for(LIBMTP_file_t *f=ls;f;f=f->next){
    if(!safe_name(f->filename)){ fprintf(stderr,"skip odd name in %s\n",rel); ps->skipped++; continue; }
    char out[2048],r2[2048]; snprintf(out,sizeof out,"%s/%s",local,f->filename); snprintf(r2,sizeof r2,"%s/%s",rel,f->filename);
    if(f->filetype==LIBMTP_FILETYPE_FOLDER) pull_tree(d,storage,f->item_id,out,r2,ps);
    else pull_file(d,f->item_id,f->filesize,out,r2,ps);
  }
  free_list(ls);
}
static int do_pull(LIBMTP_mtpdevice_t *d,uint32_t storage,const char *path,const char *dest,int overwrite){
  uint32_t id; int isdir; uint64_t sz; char nm[512];
  if(resolve(d,storage,path,&id,&isdir,&sz,nm,sizeof nm)) return 4;
  if(id==LIBMTP_FILES_AND_FOLDERS_ROOT){ fprintf(stderr,"refusing to pull the whole Kindle; pick a folder\n"); return 2; }
  if(!safe_name(nm)){ fprintf(stderr,"odd name, refusing\n"); return 2; }
  if(mkdir_p(dest)){ fprintf(stderr,"cannot create %s\n",dest); return 2; }
  pullstat ps={0,0,0,0,overwrite};
  char out[2048]; snprintf(out,sizeof out,"%s/%s",dest,nm);
  printf("pulling %s -> %s\n",path,out);
  if(isdir) pull_tree(d,storage,id,out,nm,&ps); else pull_file(d,id,sz,out,nm,&ps);
  char h[32]; human(ps.bytes,h,sizeof h);
  printf("pull done: %d file(s), %llu bytes (%s) copied into %s; %d skipped, %d failed\n",ps.files,(unsigned long long)ps.bytes,h,dest,ps.skipped,ps.failed);
  return ps.failed?1:0;
}

static void usage(FILE *o){
  fprintf(o,
"kpush.v6 - copy files to and from the Kindle Colorsoft over USB (MTP)\n"
"\n"
"usage:\n"
"  kpush.v6 [push] /kindle/folder file1 [file2 ...]\n"
"        copy Mac files into a Kindle folder (same as kpush.v5; creates missing\n"
"        subfolders, replaces same-named files, prints 'on kindle: <file> <size>')\n"
"  kpush.v6 ls [/kindle/path]\n"
"        list a Kindle folder (default /): type, size in bytes, date, name\n"
"  kpush.v6 pull [--open] [--overwrite] /kindle/path [mac_dest_dir]\n"
"        copy a file, or a whole folder, from the Kindle into mac_dest_dir\n"
"        (default ~/Kindle-files). It lands as mac_dest_dir/<name>.\n"
"        --open       open mac_dest_dir in Finder afterwards\n"
"        --overwrite  replace files already on the Mac (default: skip them)\n"
"  kpush.v6 check     connect, identify the Kindle, disconnect; writes nothing\n"
"  kpush.v6 --help    this text\n"
"\n"
"There is no delete, rename or move command. Use -- before file names that\n"
"start with '-'. Quit Calibre (and any other MTP app) first: only one app can\n"
"hold the Kindle. If it's busy, kpush stops and tells you; it never resets USB.\n");
}

int main(int argc,char**argv){
  filter_start();
  if(strcmp(LIBMTP_VERSION_STRING,"1.1.23")){fprintf(stderr,"built for libmtp 1.1.23 only, found %s\n",LIBMTP_VERSION_STRING);return 6;}
  /* ---- argument parsing ---- */
  enum { C_NONE, C_PUSH, C_LS, C_PULL, C_CHECK } cmd=C_NONE;
  int opt_open=0, opt_over=0, help=0, endflags=0;
  char **pos=calloc(argc+1,sizeof *pos); int np=0;
  for(int i=1;i<argc;i++){
    const char *a=argv[i];
    if(!endflags && !strcmp(a,"--")){ endflags=1; continue; }
    if(!endflags && a[0]=='-' && a[1]){
      if(!strcmp(a,"--help")||!strcmp(a,"-h")) help=1;
      else if(!strcmp(a,"--open")) opt_open=1;
      else if(!strcmp(a,"--overwrite")) opt_over=1;
      else if(!strcmp(a,"--check")) { if(cmd==C_NONE && np==0) cmd=C_CHECK; else {fprintf(stderr,"--check takes no other arguments\n");return 2;} }
      else { fprintf(stderr,"unknown option: %s (see kpush.v6 --help)\n",a); return 2; }
      continue;
    }
    pos[np++]=argv[i];
  }
  if(help){ usage(stdout); return 0; }
  int pi=0;
  if(cmd==C_NONE){
    if(np==0){ usage(stderr); return 2; }
    if(!strcmp(pos[0],"push")){cmd=C_PUSH;pi=1;}
    else if(!strcmp(pos[0],"ls")){cmd=C_LS;pi=1;}
    else if(!strcmp(pos[0],"pull")){cmd=C_PULL;pi=1;}
    else if(!strcmp(pos[0],"check")){cmd=C_CHECK;pi=1;}
    else if(pos[0][0]=='/'){cmd=C_PUSH;pi=0;}
    else { fprintf(stderr,"unknown command: %s (commands: push, ls, pull, check; see --help)\n",pos[0]); return 2; }
  }
  int nargs=np-pi; char **args=pos+pi;
  if((opt_open||opt_over) && cmd!=C_PULL){ fprintf(stderr,"--open and --overwrite only work with pull\n"); return 2; }
  if(cmd==C_CHECK && nargs){ fprintf(stderr,"check takes no arguments\n"); return 2; }
  if(cmd==C_LS && nargs>1){ fprintf(stderr,"usage: kpush.v6 ls [/kindle/path]\n"); return 2; }
  if(cmd==C_PULL && (nargs<1||nargs>2)){ fprintf(stderr,"usage: kpush.v6 pull [--open] [--overwrite] /kindle/path [mac_dest_dir]\n"); return 2; }
  if(cmd==C_PUSH && nargs<2){ fprintf(stderr,"usage: kpush.v6 [push] /kindle/folder file1 [file2 ...]\n"); return 2; }
  if(cmd==C_PUSH && args[0][0]!='/'){ fprintf(stderr,"push folder must start with / (got %s)\n",args[0]); return 2; }
  char dest[2048]={0};
  if(cmd==C_PULL){
    if(nargs==2){ if(args[1][0]=='~' && args[1][1]=='/') snprintf(dest,sizeof dest,"%s/%s",getenv("HOME"),args[1]+2); else snprintf(dest,sizeof dest,"%s",args[1]); }
    else { const char *h=getenv("HOME"); if(!h){fprintf(stderr,"HOME not set\n");return 2;} snprintf(dest,sizeof dest,"%s/Kindle-files",h); }
    size_t L=strlen(dest); while(L>1 && dest[L-1]=='/') dest[--L]=0;
  }

  /* ---- open the Kindle exactly as v5 does ---- */
  LIBMTP_Init();
  LIBMTP_raw_device_t *raw=NULL; int nraw=0;
  if(LIBMTP_Detect_Raw_Devices(&raw,&nraw)!=LIBMTP_ERROR_NONE||nraw<1){fprintf(stderr,"no device (is the Kindle plugged in and unlocked?)\n");return 3;}
  int k=-1;
  for(int i=0;i<nraw;i++) if(raw[i].device_entry.vendor_id==KINDLE_VID && raw[i].device_entry.product_id==COLORSOFT1_PID){k=i;break;}
  if(k<0){fprintf(stderr,"no Kindle Colorsoft (1949:9981) found; %d other MTP device(s) ignored\n",nraw);return 3;}
  if(k) raw[0]=raw[k];
  printf("found Kindle Colorsoft (1st gen), USB 1949:9981, bus %u dev %u\n",raw[0].bus_location,raw[0].devnum);
  raw[0].device_entry.device_flags &= ~((uint32_t)0x10000000);
  printf("device flags 0x%08x (reset-on-close %s)\n",raw[0].device_entry.device_flags,
         (raw[0].device_entry.device_flags & 0x10000000)?"ON":"off");
  LIBMTP_mtpdevice_t *d=LIBMTP_Open_Raw_Device_Uncached(&raw[0]);
  if(!d){fprintf(stderr,"could not open device: the Kindle is probably busy. Quit Calibre (or Android File Transfer/OpenMTP) and run again. Not retrying.\n");return 3;}
  if(no_reset_on_close(d)){LIBMTP_Release_Device(d);return 5;}
  { char *m=LIBMTP_Get_Modelname(d); printf("device reports model: %s\n",m?m:"(none)"); free(m); }
  if(cmd==C_CHECK){ no_reset_on_close(d); LIBMTP_Release_Device(d); printf("check done, nothing written\n"); return 0; }
  LIBMTP_Get_Storage(d,LIBMTP_STORAGE_SORTBY_NOTSORTED);
  if((cmd==C_LS||cmd==C_PULL) && !d->storage){fprintf(stderr,"no storage\n");no_reset_on_close(d);LIBMTP_Release_Device(d);return 3;}
  uint32_t storage=d->storage?d->storage->id:0;
  if(cmd==C_LS){ int rr=do_ls(d,storage,nargs?args[0]:"/"); no_reset_on_close(d); LIBMTP_Release_Device(d); return rr; }
  if(cmd==C_PULL){
    int rr=do_pull(d,storage,args[0],dest,opt_over); no_reset_on_close(d); LIBMTP_Release_Device(d);
    if(opt_open && rr!=4 && rr!=2){ pid_t p=fork(); if(p==0){ execlp("open","open",dest,(char*)NULL); _exit(127);} if(p>0){int st; waitpid(p,&st,0);} printf("opened %s in Finder\n",dest); }
    return rr;
  }

  /* ---- push: v5's code path, unchanged ---- */
  char path[1024]; strncpy(path,args[0],sizeof path-1); path[sizeof path-1]=0;
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
  LIBMTP_file_t *files=LIBMTP_Get_Files_And_Folders(d,storage,parent);
  int fail=0;
  for(int i=1;i<nargs;i++){
    struct stat st; if(stat(args[i],&st)){perror(args[i]);fail++;continue;}
    char *tmp=strdup(args[i]); char *bn=basename(tmp);
    for(LIBMTP_file_t *f=files;f;f=f->next) if(f->filetype!=LIBMTP_FILETYPE_FOLDER && strcmp(f->filename,bn)==0){
      if(safe_delete(d,f->item_id,parent)==0) printf("replaced old %s\n",bn); }
    LIBMTP_file_t *nf=LIBMTP_new_file_t();
    nf->filename=strdup(bn); nf->filesize=st.st_size; nf->filetype=LIBMTP_FILETYPE_UNKNOWN;
    nf->parent_id=parent; nf->storage_id=storage;
    int r=LIBMTP_Send_File_From_File(d,args[i],nf,NULL,NULL);
    printf("%s %s (%lld bytes)\n",r==0?"sent":"FAILED",bn,(long long)st.st_size);
    if(r){LIBMTP_Dump_Errorstack(d);LIBMTP_Clear_Errorstack(d);fail++;}
    LIBMTP_destroy_file_t(nf); free(tmp);
  }
  LIBMTP_file_t *after=LIBMTP_Get_Files_And_Folders(d,storage,parent);
  for(LIBMTP_file_t *f=after;f;f=f->next) printf("on kindle: %s %llu\n",f->filename,(unsigned long long)f->filesize);
  no_reset_on_close(d);
  LIBMTP_Release_Device(d);
  return fail?1:0;
}
