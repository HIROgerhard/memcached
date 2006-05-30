/* -*- Mode: C; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*- */
/* $Id$ */

#define DATA_BUFFER_SIZE 2048
#define UDP_READ_BUFFER_SIZE 65536
#define UDP_MAX_PAYLOAD_SIZE 1400
#define UDP_HEADER_SIZE 8
#define MAX_SENDBUF_SIZE (256 * 1024 * 1024)

/* Time relative to server start. Smaller than time_t on 64-bit systems. */
typedef unsigned int rel_time_t;

struct stats {
    unsigned int  curr_items;
    unsigned int  total_items;
    unsigned long long curr_bytes;
    unsigned int  curr_conns;
    unsigned int  total_conns;
    unsigned int  conn_structs;
    unsigned long long  get_cmds;
    unsigned long long  set_cmds;
    unsigned long long  get_hits;
    unsigned long long  get_misses;
    time_t        started;          /* when the process was started */
    unsigned long long bytes_read;
    unsigned long long bytes_written;
};

struct settings {
    size_t maxbytes;
    int maxconns;
    int port;
    int udpport;
    struct in_addr interface;
    int verbose;
    rel_time_t oldest_live; /* ignore existing items older than this */
    int evict_to_free;
    double factor;          /* chunk size growth factor */
    int chunk_size;
};

extern struct stats stats;
extern struct settings settings;

#define ITEM_LINKED 1
#define ITEM_DELETED 2

/* temp */
#define ITEM_SLABBED 4

typedef struct _stritem {
    struct _stritem *next;
    struct _stritem *prev;
    struct _stritem *h_next;    /* hash chain next */
    rel_time_t      time;       /* least recent access */
    rel_time_t      exptime;    /* expire time */
    int             nbytes;     /* size of data */
    unsigned short  refcount; 
    unsigned char   nsuffix;    /* length of flags-and-length string */
    unsigned char   it_flags;   /* ITEM_* above */
    unsigned char   slabs_clsid;/* which slab class we're in */
    unsigned char   nkey;       /* key length, w/terminating null and padding */
    void * end[0];
    /* then null-terminated key */
    /* then " flags length\r\n" (no terminating null) */
    /* then data with terminating \r\n (no terminating null; it's binary!) */
} item;

#define ITEM_key(item) ((char*)&((item)->end[0]))

/* warning: don't use these macros with a function, as it evals its arg twice */
#define ITEM_suffix(item) ((char*) &((item)->end[0]) + (item)->nkey)
#define ITEM_data(item) ((char*) &((item)->end[0]) + (item)->nkey + (item)->nsuffix)
#define ITEM_ntotal(item) (sizeof(struct _stritem) + (item)->nkey + (item)->nsuffix + (item)->nbytes)

enum conn_states {
    conn_listening,  /* the socket which listens for connections */
    conn_read,       /* reading in a command line */
    conn_write,      /* writing out a simple response */
    conn_nread,      /* reading in a fixed number of bytes */
    conn_swallow,    /* swallowing unnecessary bytes w/o storing */
    conn_closing,    /* closing this connection */
    conn_mwrite      /* writing out many items sequentially */
};

#define NREAD_ADD 1
#define NREAD_SET 2
#define NREAD_REPLACE 3

typedef struct {
    int    sfd;
    int    state;
    struct event event;
    short  ev_flags;
    short  which;  /* which events were just triggered */

    char   *rbuf;  
    int    rsize;  
    int    rbytes;

    char   *wbuf;
    char   *wcurr;
    int    wsize;
    int    wbytes; 
    int    write_and_go; /* which state to go into after finishing current write */
    void   *write_and_free; /* free this memory after finishing writing */

    char   *rcurr;
    int    rlbytes;
    
    /* data for the nread state */

    /* 
     * item is used to hold an item structure created after reading the command
     * line of set/add/replace commands, but before we finished reading the actual 
     * data. The data is read into ITEM_data(item) to avoid extra copying.
     */

    void   *item;     /* for commands set/add/replace  */
    int    item_comm; /* which one is it: set/add/replace */

    /* data for the swallow state */
    int    sbytes;    /* how many bytes to swallow */

    /* data for the mwrite state */
    struct iovec *iov;
    int    iovsize;   /* number of elements allocated in iov[] */
    int    iovused;   /* number of elements used in iov[] */

    struct msghdr *msglist;
    int    msgsize;   /* number of elements allocated in msglist[] */
    int    msgused;   /* number of elements used in msglist[] */
    int    msgcurr;   /* element in msglist[] being transmitted now */
    int    msgbytes;  /* number of bytes in current msg */

    item   **ilist;   /* list of items to write out */
    int    isize;
    item   **icurr;
    int    ileft;

    /* data for UDP clients */
    int    udp;       /* 1 if this is a UDP "connection" */
    int    request_id; /* Incoming UDP request ID, if this is a UDP "connection" */
    struct sockaddr request_addr; /* Who sent the most recent request */
    socklen_t request_addr_size;
    unsigned char *hdrbuf; /* udp packet headers */
    int    hdrsize;   /* number of headers' worth of space is allocated */
} conn;

/* listening socket */
extern int l_socket;

/* udp socket */
extern int u_socket;

/* current time of day (updated periodically) */
extern volatile rel_time_t current_time;

/* temporary hack */
/* #define assert(x) if(!(x)) { printf("assert failure: %s\n", #x); pre_gdb(); }
   void pre_gdb (); */

/*
 * Functions
 */

/* 
 * given time value that's either unix time or delta from current unix time, return
 * unix time. Use the fact that delta can't exceed one month (and real time value can't 
 * be that low).
 */

rel_time_t realtime(time_t exptime);

/* slabs memory allocation */

/* Init the subsystem. 1st argument is the limit on no. of bytes to allocate,
   0 if no limit. 2nd argument is the growth factor; each slab will use a chunk
   size equal to the previous slab's chunk size times this factor. */
void slabs_init(size_t limit, double factor);

/* Given object size, return id to use when allocating/freeing memory for object */
/* 0 means error: can't store such a large object */
unsigned int slabs_clsid(size_t size);

/* Allocate object of given length. 0 on error */
void *slabs_alloc(size_t size);

/* Free previously allocated object */
void slabs_free(void *ptr, size_t size);
    
/* Fill buffer with stats */
char* slabs_stats(int *buflen);

/* Request some slab be moved between classes
  1 = success
   0 = fail
   -1 = tried. busy. send again shortly. */
int slabs_reassign(unsigned char srcid, unsigned char dstid);
    
/* event handling, network IO */
void event_handler(int fd, short which, void *arg);
conn *conn_new(int sfd, int init_state, int event_flags, int read_buffer_size, int is_udp);
void conn_close(conn *c);
void conn_init(void);
void drive_machine(conn *c);
int new_socket(int isUdp);
int server_socket(int port, int isUdp);
int update_event(conn *c, int new_flags);
int try_read_command(conn *c);
int try_read_network(conn *c);
int try_read_udp(conn *c);
void complete_nread(conn *c);
void process_command(conn *c, char *command);
int transmit(conn *c);
int ensure_iov_space(conn *c);
int add_iov(conn *c, void *buf, int len);
int add_msghdr(conn *c);

/* stats */
void stats_reset(void);
void stats_init(void);

/* defaults */
void settings_init(void);

/* associative array */
void assoc_init(void);
item *assoc_find(char *key);
int assoc_insert(char *key, item *item);
void assoc_delete(char *key);


void item_init(void);
item *item_alloc(char *key, int flags, rel_time_t exptime, int nbytes);
void item_free(item *it);

int item_link(item *it);    /* may fail if transgresses limits */
void item_unlink(item *it);
void item_remove(item *it);

void item_update(item *it);   /* update LRU time to current and reposition */
int item_replace(item *it, item *new_it);
char *item_cachedump(unsigned int slabs_clsid, unsigned int limit, unsigned int *bytes);
char *item_stats_sizes(int *bytes);
void item_stats(char *buffer, int buflen);
