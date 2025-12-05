//helpers
function findObjectByKey(array, key, value) {
  for (var i = 0; i < array.length; i++) {
    if (array[i][key] === value) {
      return array[i];
    }
  }
  return null;
}
function findIndexByKey(array, key, value) {
  for (var i = 0; i < array.length; i++) {
    if (array[i][key] === value) {
      return i;
    }
  }
  return null;
}

class LiveMap {

    constructor(_config, _car_data,_map_data) {
      this.config = {
        parentElement: _config.parentElement,
        containerWidth: _config.containerWidth || 700,
        containerHeight: _config.containerHeight || 700,
        margin: { top: 25, bottom: 25, right: 25, left: 25}
      }
      this.map_data = _map_data;
      this.racer_data = _car_data;
      this.rt_data = [];
      // Call a class function
      this.initVis();
    }
  
    initVis() {
      let vis = this;
      vis.startTime = Date.now();
	    vis.splitTime = vis.startTime;
      vis.width = vis.config.containerWidth - vis.config.margin.left - vis.config.margin.right;
      vis.height = vis.config.containerHeight - vis.config.margin.top - vis.config.margin.bottom;
  
      // Setup Socket for local TCP data serving, TODO: add one for database for SMARL website
      var socket = io.connect('http://' + location.hostname + ':' + location.port);
      socket.on( 'connect', function() {
        console.log("Socket connected!")    
      });
       
      socket.on('raceData', function( data ) {
        if (data == null){return}
        let size = Object.keys(data).length; 
        if(size > 0){
          //console.log('set data',data)
          vis.rt_data = data.realtime_data;
          vis.updateVis(vis.racer_data);
        }else{
          console.log("Data Size 0");
        }
      });
      vis.all_elements = [];

      // Atttempting to get things working just from using the scaled domain and range
      // We may need to get an offset value to apply across X and y if this doesnt work.
      vis.xScale = d3.scaleLinear()
          .domain(d3.extent(this.map_data, d=> d.midX))
          .range([0, vis.width]);
  
      vis.yScale = d3.scaleLinear()
          .domain(d3.extent(this.map_data, d => d.midY))
          .range([vis.height, 0]) // May need to inverse?
       
  
      // Define size of SVG drawing area
      vis.svg = d3.select(vis.config.parentElement)
          .attr('width', vis.config.containerWidth)
          .attr('height', vis.config.containerHeight);
  
      // Append group element that will contain our actual chart (see margin convention)
      vis.chart = vis.svg.append('g')
          .attr('transform', `translate(${vis.config.margin.left},${vis.config.margin.top})`);

      
      vis.xValue = d => d.midX;
      vis.yValue = d => d.midY;
      vis.width = d => d.width;
      vis.line = d3.line() // Sets up Line for track path
          .x(d => vis.xScale(vis.xValue(d)))
          .y(d => vis.yScale(vis.yValue(d)));
      // Set the scale input domains
      //vis.xScale.domain(d3.extent(vis.map_data, vis.xValue)); // Uses extent of track path for scaling??
      //vis.yScale.domain(d3.extent(vis.map_data, vis.yValue));   
  
     //console.log(vis.map_data)
      // Outer path outline 
      /* Removed because unecessary
      vis.chart.append('path')
      //.data([vis.data])
      .attr('class', 'chart-line')
      .attr('d',vis.line(vis.map_data))
      .attr("fill", "none")
      .attr("stroke", "black")
      .attr("stroke-width",45)
      */

      // inner path outline
      vis.chart.append('path')
      //.data([vis.data])
      .attr('class', 'chart-line')
      .attr('d',vis.line(vis.map_data))
      .attr("fill", "none")
      .attr("stroke", "#FFFFFFB0")
      .attr("stroke-width",45) // TODO make a scale function that scales according to chart size

      vis.updateVis();
    }
  
  
    //We will add live Cars and live data 
   updateVis(racer_data) { 
    let vis = this;
    vis.racer_data = racer_data || [];

    let elapsedTime = Date.now() - vis.splitTime;
    vis.splitTime = Date.now() // immediately reset??
  //console.log("updating live map",elapsedTime);
    // Initial creation of live cars
    let rt_racers = vis.rt_data; // Realtime Data
    console.log("Rtracer",rt_racers)
    if (rt_racers == null){ rt_racers = []}	
 
    // Secondary color (background thin ring)
    vis.racerMarkerS = vis.chart.selectAll(".racerMarkerS") // Secondary color
    .data(rt_racers)
    vis.racerMarkerS.enter()
    .append('circle')
    .attr("class","racerMarkerS")
    .attr("cx",function(d,i){
      return vis.xScale(d.locX)
    })
    .attr('cy',function(d,i){
      console.log("set y",d)
      return vis.yScale(d.locY)
    })
    .attr("opacity",0)
    .transition() // spawned in
    .attr("cx",function(d,i){
      return vis.xScale(d.locX)
    })
    .attr('cy',function(d,i){
      return vis.yScale(d.locY)
    })
    .attr("opacity",0.90)
    .attr("r",function(d,i){
      return 20
    })
    .attr("fill",function(d,i){ 
      let color = d['secondary_color'];
			// If the first character is NOT '#', prepend '#'
			return (color.charAt(0) === '#') ? color : "#" + color;
    })
    .attr('stroke',function(d,i){
      let color = d['tertiary_color'];
			// If the first character is NOT '#', prepend '#'
			return (color.charAt(0) === '#') ? color : "#" + color;
    })
    .attr("stroke-width",2) // TODO make a scale function that scales according to chart size

    .duration(100)

    vis.racerMarkerS.transition() // when racer moves
    .attr("cx",function(d,i){
      return vis.xScale(d.locX)
    })
    .attr('cy',function(d,i){
      return vis.yScale(d.locY)
    })
    .attr("opacity",0.90)
    .attr("r",function(d,i){
      return 20
    })

    .ease(d3.easeLinear)
    .duration(elapsedTime)

    vis.racerMarkerS.exit()
    .transition()
    .attr("opacity",0)
    .attr("r",function(d,i){
      return 0 
    }) 
    .duration("750")
    .remove()

    
    vis.racerMarker = vis.chart.selectAll(".racerMarker")
    .data(rt_racers)
    vis.racerMarker.enter()
    .append('circle')
    .attr("class","racerMarker")
    .attr("cx",function(d,i){
      return vis.xScale(d.locX)
    })
    .attr('cy',function(d,i){
      return vis.yScale(d.locY)
    })
    .attr("opacity",0)
    .transition() // spawned in
    .attr("cx",function(d,i){
      return vis.xScale(d.locX)
    })
    .attr('cy',function(d,i){
      return vis.yScale(d.locY)
    })
    .attr("opacity",1)
    .attr("r",function(d,i){
      return 13
    }) 
    .attr("fill",function(d,i){ // TODO: make based off of car primary color?, stroke off of secondary
      //let car = findObjectByKey(vis.racer_data,'id',d.id)
      let color = d['primary_color'];
			// If the first character is NOT '#', prepend '#'
			return (color.charAt(0) === '#') ? color : "#" + color;
    })
    .attr('stroke',function(d,i){
      return "none"
    })	
    .duration(100)

    vis.racerMarker.transition() // when racer moves
    .attr("cx",function(d,i){
      return vis.xScale(d.locX)
    })
    .attr('cy',function(d,i){
      return vis.yScale(d.locY)
    })
    .attr("r",function(d,i){
      return 13
    })
    .attr("opacity",1)

    .ease(d3.easeLinear)
    .duration(elapsedTime)

    vis.racerMarker.exit()
    .transition()
    .attr("opacity",0)
    .attr("r",function(d,i){
      return 0 
    }) // TODO: make proportionate to health??
    .duration("750")
    .remove()


      vis.renderVis();
   }
   
  
  
    /**
     * This function contains the D3 code for binding data to visual elements
     * Important: the chart is not interactive yet and renderVis() is intended
     * to be called only once; otherwise new paths would be added on top
     */
    renderVis() {
      let vis = this;

      
      
     
  
          
          // racer usernames
          /*
          nameText = interactive_chart.selectAll(".nameText")
          .data(all_cows)
    
          nameText.enter()
          .append('text')
          .attr('class','nameText')
          .attr("x", function(d,i){
            return xScale(d.p['x'])
          })
          .attr('y',function(d,i){
            return xScale(d.p['y']) - 10 // TODO: figure out good/dynamic height
          })
          .attr('dx',"0em") // put offset here?
          .attr('dy',"0em")
          .text(function(d,i){ return d['n']})
          .attr('font-family',"sans-serif")
          .attr('font-size','12px')
          .attr('stroke','white')
          .attr('stroke-width',0.3)			
          .attr('fill','#3377ff')
          .attr('text-anchor', 'middle')
          .attr('alignment-baseline', 'central')
          .attr("opacity",0)
          .transition()
          .attr("opacity",1)
          .duration(500)
    
          nameText.transition()
          .attr("x", function(d,i){
            return xScale(d.p['x'])
          })
          .attr('y',function(d,i){
            return xScale(d.p['y']) - 10 // TODO: figure out good/dynamic height
          })
          .attr('dx',"0em") // put offset here?
          .attr('dy',"0em")
          .attr('fill','#3377ff')
          .attr("opacity",1)
          .text(function(d,i){ return d['n']})
          .ease(d3.easeLinear)
          .duration(elapsedTime)
    
    
          nameText.exit()
          .transition()
          .attr("opacity",0)
          .duration(500)
          .remove()
          all_elements.push(nameText)
          */


    }
  
  }