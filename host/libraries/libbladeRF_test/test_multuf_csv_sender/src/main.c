/*
 * This file is part of the bladeRF project:
 *   http://www.github.com/nuand/bladeRF
 *
 * Copyright (C) 2015 Nuand LLC
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#include <getopt.h>
#include <stdlib.h>
#include <unistd.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include <signal.h>
#include <libbladeRF.h>
#include "test_common.h"
#include "conversions.h"
#include "host_config.h"
#include "include.h"
#include "devcfg.h"
#include "log.h"

#define VERBOSITY BLADERF_LOG_LEVEL_VERBOSE

#define BUF_LEN    8192
#define TIMEOUT_MS 2500
#define SAMPLE_RATE 2000000
#define BANDWIDTH   5000000

#define BLADERF2_CENTER_FREQ ((bladerf_frequency) 3.000e9)
#define BLADERF2_START_FREQ ((bladerf_frequency) 1.600e9)
#define BLADERF2_STOP_FREQ ((bladerf_frequency) 1.630e9)
#define ITERATIONS 500
#define DWELL_TIME (100000)
#define LINE_LENGTH 256

bool is_running = true;
struct devcfg config;

void sig_handler(int signo)
{
    if (signo == SIGINT) {
        fprintf(stderr, "received SIGINT\n");
        if (!is_running) {
            fprintf(stderr, "received another SIGINT, aborting\n");
            abort();
        }
        is_running = false;
    }
}


int countlines(char *filename)
{
    // count the number of lines in the file called filename                                    
    FILE *fp = fopen(filename,"r");
    int ch=0;
    int lines=0;

    if (fp == NULL){
        printf("could not open %s\n", filename);
        return 0;
    }

    lines++;
    while(!feof(fp)) {
        ch = fgetc(fp);
        if(ch == '\n') {
            lines++;
        }
    }

    fclose(fp);
    return lines;
}

frequency_sweep* read_csv(char* filename, int* sweep_count){
    FILE *fp;
    char row[LINE_LENGTH];
    char *token;
    frequency_sweep* sweeps;
    char* result;
    int i=0;
    
    *sweep_count=countlines(filename);
    if(*sweep_count==0){
        printf("empty file\n");
        return NULL;
    }


    sweeps = (frequency_sweep*) malloc((*sweep_count) * sizeof(frequency_sweep));
    if(sweeps==NULL){
        printf("could not malloc %d sweeps\n", *sweep_count);
        return NULL;
    }


    fp = fopen(filename,"r");
    if (fp == NULL){
        printf("could not open %s\n", filename);
        free(sweeps);
        return 0;
    }
    while (feof(fp) != true)
    {
        result=fgets(row, LINE_LENGTH, fp);
        if(result==NULL) {
            printf("Could not read row: %s %ld\n", row, (long int) result);
            i--;
            return sweeps;
        }

        token = strtok(row, ",");
        sweeps[i].start_sweep=atoi(token);
        printf("start: %s\n", token);

        token = strtok(NULL, ",");
        sweeps[i].stop_sweep=atoi(token);
        printf("stop: %s\n", token);

        token = strtok(NULL, ",");
        sweeps[i].step_count=atoi(token);
        printf("count: %s\n", token);

        token = strtok(NULL, ",");
        sweeps[i].step_duration=atoi(token);
        printf("duration: %s\n", token);
        // while(token != NULL)
        // {
        //     printf("Token: %s\n", token);
        //     token = strtok(NULL, ",");
        // }
        i++;
    }

    fclose(fp);
    return sweeps;
}


int run_test_multuf_v2_sender(struct bladerf *dev, frequency_sweep* sweeps, int sweep_count)
{
    int status;
    int16_t *samples = NULL;
    unsigned int i;
    struct bladerf_metadata meta;
    sweep_metadata sweep_meta;
    memset(&meta, 0, sizeof(meta));
    memset(&sweep_meta, 0, sizeof(sweep_meta));


    sweep_meta.sweep = sweeps;
    sweep_meta.sweep_count = sweep_count;
    sweep_meta.dir = BLADERF_CHANNEL_IS_TX(BLADERF_CHANNEL_TX(0));

    samples = malloc(2 * BUF_LEN * sizeof(samples[0]));
    if (samples == NULL) {
        perror("malloc");
        return BLADERF_ERR_MEM;
    }

    /* Just send a carrier tone */
    for (i = 0; i < (2 * BUF_LEN); i += 2) {
        samples[i] = samples[i+1] = 1448;;
    }

    status = devcfg_perform_sync_config(dev, BLADERF_TX_X1,
                                        BLADERF_FORMAT_SC16_Q11_META,
                                        &config, true);
    if (status != 0) {
        bladerf_close(dev);
        return -1;
    }

    status = bladerf_get_timestamp(dev, BLADERF_MODULE_TX, &meta.timestamp);
    if (status != 0) {
        fprintf(stderr, "Failed to get initial timestamp: %s\n",
                bladerf_strerror(status));
        goto out;
    }

    /* Add some initial startup delay */
    meta.timestamp += DWELL_TIME;   // ~150ms

    // if (module == BLADERF_MODULE_TX) { 
    meta.flags = BLADERF_META_FLAG_TX_BURST_START | BLADERF_META_FLAG_TX_BURST_END;
    // meta.flags = BLADERF_META_FLAG_TX_BURST_START | BLADERF_META_FLAG_TX_NOW | BLADERF_META_FLAG_TX_BURST_END;
    // meta.flags = BLADERF_META_FLAG_TX_BURST_START | BLADERF_META_FLAG_TX_NOW;
    // } else {
        // meta.flags = 0;
    // }



    status = bladerf_set_scan(dev,
                    BLADERF_CHANNEL_TX(0),
                    &meta,
                    &sweep_meta);
    printf ( "%s:%d scan set status %d\n", __FILE__, __LINE__, status);
    if (status != 0) {
        fprintf(stderr, "Failed to set scan: %s\n",
                bladerf_strerror(status));
        goto out;
    }

    // status = bladerf_get_timestamp(dev, BLADERF_MODULE_TX, &meta.timestamp);
    // if (status != 0) {
    //     fprintf(stderr, "Failed to get initial timestamp before tx: %s\n",
    //             bladerf_strerror(status));
    //     goto out;
    // }
    // meta.timestamp += DWELL_TIME;     // ~30ms


    while(1) {
        // bladerf_frequency test;
        printf("sync tx------------------------\n");
        status = bladerf_sync_tx(dev, samples, BUF_LEN, &meta, TIMEOUT_MS);
        if (status != 0) {
            fprintf(stderr, "Failed to TX data: %s\n",
                    bladerf_strerror(status));
            goto out;
        }
        printf("--------------------------------------tx\n\n");
        get_next_scan_timestamp(dev, &sweep_meta);

        // status = wait_for_timestamp(
        //     dev, BLADERF_TX, sweep_meta.next_timestamp+1000, TIMEOUT_MS);
        // if (status != 0) {
        //     fprintf(stderr, "Failed to wait for timestamp.\n");
        // }
        
        // status = bladerf_get_timestamp(dev, BLADERF_CHANNEL_IS_TX(BLADERF_CHANNEL_TX(0)), &meta.timestamp);
        // if(status!=0){
        //     fprintf(stderr, "Failed to get timestamp %s\n",
        //             bladerf_strerror(status));
        //     return status;
        // }
        // printf("real:%ld, expected:%ld\n", meta.timestamp, sweep_meta.next_timestamp);
        // bladerf_get_frequency(dev, BLADERF_CHANNEL_TX(0), &test);
        // if(status!=0){
        //     fprintf(stderr, "Failed to get freq %s\n",
        //             bladerf_strerror(status));
        //     return status;
        // }
        // printf("received freq:%ld\n", test);
        meta.timestamp = sweep_meta.next_timestamp;
    }

out:
    free(samples);
    printf("bladerf close------------------------\n");
    bladerf_enable_module(dev, BLADERF_CHANNEL_TX(0), false);
    printf("--------------------------------------\n\n");
    return status;
}



int main(int argc, char *argv[])
{
    int sweep_count; 
    int i;
    frequency_sweep* sweeps;
    sweeps = read_csv("deneme.csv", &sweep_count);
    printf("sweep_count=%d\n", sweep_count);
    for(i=0;i<sweep_count;i++){
        printf("sweep_start=%d\n", sweeps[i].start_sweep);
        printf("sweep_stop=%d\n", sweeps[i].stop_sweep);
        printf("sweep_count=%d\n", sweeps[i].step_count);
        printf("sweep_duration=%ld\n", sweeps[i].step_duration);
    }

    

    int status;
    struct bladerf *dev = NULL;
    const char *devstr = NULL;
    // pthread_t receiver_td;

    if (signal(SIGINT, sig_handler) == SIG_ERR) {
        fprintf(stderr, "Unable to catch SIGINT signals\n");
    }

    bladerf_log_set_verbosity(VERBOSITY);

    status = bladerf_open(&dev, devstr);
    if (status != 0) {
        fprintf(stderr, "Unable to open device: %s\n",
                bladerf_strerror(status));
        return status;
    }
    printf("deneme0\n");
    devcfg_init(&config);
    printf("deneme1\n");
    config.tx_samplerate = SAMPLE_RATE;
    config.tx_bandwidth  = BANDWIDTH;

    config.samples_per_buffer = BUF_LEN;
    config.num_buffers = 16;
    config.num_transfers = 8;

    status = devcfg_apply(dev, &config);
    if (status != 0) {
        fprintf(stderr, "Failed to configure device.\n");
        bladerf_close(dev);
        return -1;
    }

    printf("deneme\n");


    printf("status\n");
    printf("deneme2\n");
    status = run_test_multuf_v2_sender(dev, sweeps, sweep_count);
    if (status != 0) {
        fprintf(stderr, "Failed at run test: %s\n",
                bladerf_strerror(status));
        // bladerf_close(dev);
        // return -1;
    }    

    printf("deneme3\n");
   

    printf("deneme4\n");
    status = bladerf_enable_module(dev, BLADERF_TX_X1, false);
    if (status != 0) {
        fprintf(stderr, "Failed to status TX module: %s\n",
                bladerf_strerror(status));
        bladerf_close(dev);
        return -1;
    }    
    printf("deneme5\n");

    bladerf_close(dev);
    return status;


}
